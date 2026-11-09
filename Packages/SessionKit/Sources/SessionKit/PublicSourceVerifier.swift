import Foundation

/// Decides, from one anonymous look at the source's public address, whether a source is public enough to earn a
/// `PublicSourceMark` (#3449, owner 2026-11-05).
///
/// The mark only decides what leaves the phone (`MapTextDisclosure`); the on-device model reads every source either way.
/// This type does the looking and nothing else: it holds no session, cookies or credentials of its own. The request is
/// made by an injected `Probe`, which the app backs with an ephemeral, cookie-free session that follows no redirect by
/// itself, and which tests replace with a table of canned answers.
///
/// Callers run it only on a listener's action (adding the item, the Prepare Listening Map tap, a share or export tap).
/// `scripts/tests/test_public_source_check_callers.py` fails when a background path reaches it.
public struct PublicSourceVerifier: Sendable {
    /// What a probe is for. A page is read as text; an audio start asks for the first byte of the enclosure.
    public enum Purpose: Sendable { case page, audioStart }

    /// One answer to one request. A redirect is reported, not followed, so the verifier judges every hop.
    public struct Response: Equatable, Sendable {
        public var status: Int
        public var contentType: String?
        /// The `Location` of a 3xx answer, already resolved against the request address.
        public var redirect: URL?
        public var body: Data

        public init(status: Int, contentType: String? = nil, redirect: URL? = nil, body: Data = Data()) {
            self.status = status
            self.contentType = contentType
            self.redirect = redirect
            self.body = body
        }
    }

    public typealias Probe = @Sendable (_ url: URL, _ purpose: Purpose) async throws -> Response

    public enum Outcome: Equatable, Sendable {
        /// The source answered anonymously and matched.
        case marked(PublicSourceMark)
        /// It answered, and it is not public or is not this source: a login, a teaser, a missing page, another article,
        /// or a kind of source that has no public copy.
        case notPublic
        /// Offline, timed out, or a server fault. The next tap tries again.
        case couldNotCheck
    }

    /// Redirect hops followed before giving up. Publishers redirect to https, to `www` and to a canonical path.
    public static let maximumRedirects = 4
    /// Time allowed for the whole check, redirects included. A share tap never waits longer (#3449 default 6).
    public static let defaultTimeout: Duration = .seconds(12)
    /// Sentences sampled from the listener's copy, and the share of them the public page must hold.
    public static let minimumSamples = 3
    public static let maximumSamples = 6
    public static let requiredShare = 0.8

    private let probe: Probe

    public init(probe: @escaping Probe) {
        self.probe = probe
    }

    public func verify(_ item: Item, now: Date = Date(), timeout: Duration = PublicSourceVerifier.defaultTimeout) async -> Outcome {
        guard let address = MapTextDisclosure.checkableAddress(of: item) else { return .notPublic }
        let result: Outcome? = await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await verifyWithoutDeadline(item, address: address, now: now) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return result ?? .couldNotCheck
    }

    // MARK: Routes

    private func verifyWithoutDeadline(_ item: Item, address: String, now: Date) async -> Outcome {
        let matched: Bool?
        if let media = item.media, media.sourceType == .remoteStream, let enclosure = media.url {
            matched = await enclosureAnswers(enclosure)
        } else if let text = item.text {
            matched = await pageHolds(text, at: address)
        } else {
            matched = false
        }
        switch matched {
        case true?: return .marked(PublicSourceMark(url: address, checkedAt: now))
        case false?: return .notPublic
        case nil: return .couldNotCheck
        }
    }

    /// Audio: the enclosure link carries no secret and answers anonymously with audio, so anyone can fetch the episode.
    private func enclosureAnswers(_ enclosure: String) async -> Bool? {
        guard let link = ShareableLinkPolicy.shareableLink(enclosure), let url = URL(string: link),
              Self.isPlainHTTPS(url) else { return false }
        switch await follow(url, purpose: .audioStart, checksHops: false) {
        case .answer(let response):
            guard response.status == 200 || response.status == 206 else { return false }
            return Self.isAudioContentType(response.contentType)
        case .refused: return false
        case .unreachable: return nil
        }
    }

    /// Text: sampled sentences of the listener's copy appear in the page an anonymous visitor gets.
    private func pageHolds(_ text: String, at address: String) async -> Bool? {
        let samples = Self.sampledSentences(of: text)
        guard samples.count >= Self.minimumSamples, let url = URL(string: address) else { return false }
        switch await follow(url, purpose: .page, checksHops: true) {
        case .answer(let response):
            guard response.status == 200, Self.isTextContentType(response.contentType) else { return false }
            let page = Self.compact(Self.visibleText(ofHTML: response.body))
            guard !page.isEmpty else { return false }
            let found = samples.filter { page.contains($0) }.count
            return Double(found) >= (Self.requiredShare * Double(samples.count)).rounded(.up)
        case .refused: return false
        case .unreachable: return nil
        }
    }

    // MARK: Requests

    private enum Followed {
        case answer(Response)
        /// A hop the policy refuses (not https, a login address, too many redirects). Not public.
        case refused
        /// The probe threw (offline, timed out, cancelled) or the server faulted.
        case unreachable
    }

    private func follow(_ start: URL, purpose: Purpose, checksHops: Bool) async -> Followed {
        var url = start
        for _ in 0...Self.maximumRedirects {
            let response: Response
            do { response = try await probe(url, purpose) } catch { return .unreachable }
            if (300..<400).contains(response.status) {
                guard let next = response.redirect, Self.isPlainHTTPS(next) else { return .refused }
                if checksHops, Self.looksLikeAGate(next) { return .refused }
                url = next
                continue
            }
            if response.status == 429 || response.status >= 500 { return .unreachable }
            return .answer(response)
        }
        return .refused
    }

    public static func isPlainHTTPS(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" && components.user == nil && components.password == nil
            && MapTextDisclosure.isPublicInternetHost(components.host ?? "")
    }

    /// A redirect to a sign-in or subscribe page is a gate, not the article. A 200 login page has no sentences of the
    /// listener's copy anyway; this refuses early and keeps the cookie-less request from wandering through a login flow.
    /// Whole words only, so "accountability" in a slug is not a gate. A slug that does name one gets no mark: the safe side.
    public static func looksLikeAGate(_ url: URL) -> Bool {
        let gateWords: Set<String> = ["login", "logon", "signin", "signup", "register", "subscribe", "subscription", "paywall",
                                      "account", "auth", "oauth", "sso", "membership", "members"]
        let tokens = ((url.host ?? "") + "/" + url.path).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: gateWords.contains) { return true }
        return zip(tokens, tokens.dropFirst()).contains { ["sign", "log"].contains($0) && ["in", "up", "on"].contains($1) }
    }

    static func isTextContentType(_ value: String?) -> Bool {
        guard let type = value?.lowercased() else { return true } // some servers send none; the sentences decide
        return type.hasPrefix("text/html") || type.hasPrefix("application/xhtml") || type.hasPrefix("text/plain")
    }

    /// Anything but a page: a login or error page served with a 200 answers `text/html`, and is not an episode.
    static func isAudioContentType(_ value: String?) -> Bool {
        guard let type = value?.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return false }
        return type.hasPrefix("audio/") || type.hasPrefix("video/") || type == "application/octet-stream"
            || type == "binary/octet-stream" || type == "application/ogg"
    }

    // MARK: Matching text

    /// Sentences of the listener's copy, spread across the whole of it so a teaser holding only the opening cannot match.
    /// Each is reduced with `compact`. Fewer than `minimumSamples` usable sentences means the copy cannot be checked.
    static func sampledSentences(of text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var seen = Set<String>()
        var current = ""
        func flush() {
            let words = current.split(whereSeparator: \.isWhitespace).count
            let compacted = compact(current)
            if words >= 8, compacted.count >= 40, compacted.count <= 600, seen.insert(compacted).inserted {
                sentences.append(compacted)
            }
            current = ""
        }
        for (index, character) in characters.enumerated() {
            if character.isNewline { flush(); continue }
            current.append(character)
            if ".!?".contains(character), index + 1 >= characters.count || characters[index + 1].isWhitespace { flush() }
        }
        flush()
        guard sentences.count > Self.maximumSamples else { return sentences }
        let last = Self.maximumSamples - 1
        return (0...last).map { sentences[$0 * (sentences.count - 1) / last] }
    }

    /// Letters and digits only, folded to one case without accents or width, so curly quotes, dashes, entities, line
    /// breaks and spacing never decide a match.
    static func compact(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The text a visitor reads: the page without scripts, styles, comments and tags, with character references decoded.
    public static func visibleText(ofHTML body: Data) -> String {
        var html = String(decoding: body, as: UTF8.self)
        for block in ["script", "style", "noscript", "template", "svg", "head"] {
            html = html.replacingOccurrences(of: "<\(block)\\b[^>]*>[\\s\\S]*?</\(block)\\s*>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        html = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        // A quoted attribute may hold a ">" and a whole article; it is markup, not what a visitor reads.
        html = html.replacingOccurrences(of: "<(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", with: " ", options: .regularExpression)
        return decodeCharacterReferences(html)
    }

    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}",
        "eacute": "\u{E9}", "egrave": "\u{E8}", "agrave": "\u{E0}", "uuml": "\u{FC}", "ouml": "\u{F6}", "auml": "\u{E4}",
    ]

    private static func decodeCharacterReferences(_ value: String) -> String {
        guard value.contains("&"), let expression = try? NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);") else { return value }
        let source = value as NSString
        var result = ""
        var cursor = 0
        for match in expression.matches(in: value, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = source.substring(with: match.range(at: 1))
            var decoded: String?
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let scalar = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                decoded = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = namedReferences[name]
            }
            result += decoded ?? source.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}
