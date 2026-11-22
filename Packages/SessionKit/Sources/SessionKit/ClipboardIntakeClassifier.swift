import Foundation

/// What a Paste & go tap found on the clipboard (#145).
public enum ClipboardIntake: Equatable, Sendable {
    /// A web link: the podcast resolver tries it first, then the readable-article fallback.
    case link(URL)
    /// Copied text, imported as a text item. The title is taken from the first words.
    case text(title: String, body: String)
    /// Nothing worth adding; the reason is shown inline and nothing is created.
    case unusable(ClipboardIntakeUnusableReason)
}

public enum ClipboardIntakeUnusableReason: Equatable, Sendable {
    case empty
    case unsupportedLink(scheme: String)

    public var message: String {
        switch self {
        case .empty:
            "The clipboard is empty. Copy a link or some text first."
        case .unsupportedLink(let scheme):
            "Spoken Margins can't open \(scheme): links. Copy a web link (https) or some text instead."
        }
    }
}

/// Decides whether pasted content is a link, text to read, or nothing usable.
/// Pure and Foundation-only so it runs in the Linux host tests.
public enum ClipboardIntakeClassifier {
    /// Words taken from the start of the text for its title, matching the text import's own fallback.
    public static let titleWordLimit = 8
    /// A share sheet copies "Episode title https://…", or the title and the link on two lines, or a note before the link.
    /// Text with exactly one web link and no more than this many characters around it (the note, not the link, so a long
    /// tracking link doesn't count against it) is that link, on one line or several (#4809).
    public static let shortNoteLimit = 280

    /// "notes.txt" or "Node.js" on its own is a file or product name, not a site.
    private static let fileExtensions: Set<String> = [
        "js", "ts", "txt", "md", "html", "htm", "json", "xml", "csv", "pdf", "epub", "doc", "docx",
        "swift", "py", "rb", "png", "jpg", "jpeg", "gif", "heic", "mp3", "m4a", "m4b", "wav", "mov", "mp4", "zip",
    ]
    private static let subscriptionSchemes: Set<String> = ["feed", "itpc", "pcast", "podcast", "podcasts"]

    public static func classify(_ content: String?) -> ClipboardIntake {
        let trimmed = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unusable(.empty) }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.count == 1 {
            let token = stripWrapping(tokens[0])
            if let url = webURL(from: token) { return .link(url) }
            if let scheme = scheme(of: token), !["http", "https"].contains(scheme) {
                return .unusable(.unsupportedLink(scheme: scheme))
            }
        }

        if let link = linkWithShortNote(in: tokens, totalLength: trimmed.count) { return .link(link) }

        return .text(title: title(for: trimmed), body: trimmed)
    }

    /// The link of a short note around exactly one web link, however many lines the note has. Two links are ambiguous and a
    /// longer note is the listener's text, so both are nil. Only a short note is ever scanned, so a pasted article costs
    /// no more than its word count.
    private static func linkWithShortNote(in tokens: [String], totalLength: Int) -> URL? {
        guard tokens.count <= shortNoteLimit / 2 + 1 else { return nil }
        var found: (url: URL, length: Int)?
        for token in tokens {
            // Most words hold no link; skipping them first keeps a long run of brackets from being stripped one by one.
            guard token.range(of: "http", options: .caseInsensitive) != nil else { continue }
            var candidate = stripWrapping(token)
            // The address of a Markdown link with spaces in its text: "[Hear it](https://…)" is "it](https://…)" here.
            // Two Markdown links stuck together are two links.
            if let close = candidate.range(of: "](http", options: [.caseInsensitive, .backwards]) {
                if candidate.range(of: "](http", options: .caseInsensitive)?.lowerBound != close.lowerBound { return nil }
                candidate = stripWrapping(String(candidate[candidate.index(close.lowerBound, offsetBy: 2)...]))
            }
            guard let scheme = scheme(of: candidate), ["http", "https"].contains(scheme),
                  let url = webURL(from: candidate) else { continue }
            if let existing = found {
                // The same address twice ("Title" then the link, then the link again) is still one link.
                guard existing.url == url else { return nil }
                found?.length = existing.length + token.count
                continue
            }
            found = (url, token.count)
        }
        guard let found, totalLength - found.length <= shortNoteLimit else { return nil }
        return found.url
    }

    /// The first words of the first non-empty line, without Markdown heading marks.
    public static func title(for text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let withoutHeading = firstLine.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        let words = withoutHeading.split(whereSeparator: { $0.isWhitespace }).prefix(titleWordLimit)
        let title = words.joined(separator: " ")
        return title.isEmpty ? "Pasted text" : title
    }

    /// An http(s) URL with a host, a podcast-subscription scheme rewritten to https, or a bare domain like "example.com/post".
    private static func webURL(from token: String) -> URL? {
        if let scheme = scheme(of: token) {
            if ["http", "https"].contains(scheme) {
                guard let url = URL(string: token), let host = url.host, !host.isEmpty else { return nil }
                return url
            }
            if subscriptionSchemes.contains(scheme) {
                var rest = String(token.dropFirst(scheme.count + 1))
                if rest.lowercased().hasPrefix("http://") || rest.lowercased().hasPrefix("https://") {
                    return webURL(from: rest)
                }
                while rest.hasPrefix("/") { rest.removeFirst() }
                return webURL(from: "https://" + rest)
            }
            return nil
        }
        guard isBareDomainPath(token), let url = URL(string: "https://" + token), url.host != nil else { return nil }
        return url
    }

    private static func scheme(of token: String) -> String? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let scheme = token[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        // "Note:" or "Re:" followed by more text is prose, not a scheme; real links continue straight after the colon.
        let rest = token[token.index(after: colon)...]
        guard !rest.isEmpty else { return nil }
        return scheme.lowercased()
    }

    private static func isBareDomainPath(_ token: String) -> Bool {
        guard !token.contains("@") else { return false }
        let hostPart = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? token
        let labels = hostPart.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isASCII && $0.isLetter }),
              !fileExtensions.contains(tld.lowercased()) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Drops quotes, brackets and sentence punctuation that cling to a link copied out of prose.
    static func stripWrapping(_ token: String) -> String {
        let leading: Set<Character> = ["<", "(", "[", "\"", "'", "“", "‘", "«"]
        let trailing: Set<Character> = [">", ")", "]", "\"", "'", "”", "’", "»", ".", ",", ";", ":", "!", "?"]
        let pairs: [Character: Character] = [")": "(", "]": "["]
        var result = Substring(token)
        while let first = result.first, leading.contains(first) { result = result.dropFirst() }
        // Bracket counts are kept as characters drop, so a long run of brackets costs one pass, not one per bracket.
        var counts: [Character: Int] = [:]
        for character in result where "()[]".contains(character) { counts[character, default: 0] += 1 }
        while let last = result.last, trailing.contains(last) {
            // Keep a bracket the link itself opened, as in "…/wiki/Mercury_(planet)".
            if let opener = pairs[last], counts[last, default: 0] <= counts[opener, default: 0] { break }
            if "()[]".contains(last) { counts[last, default: 0] -= 1 }
            result = result.dropLast()
        }
        return String(result)
    }
}

/// The way out when the app can't read an article link itself (#145): open it in Safari and share it back,
/// because the share extension receives the page as Safari rendered it, including pages behind a login.
public struct OpenInSafariOffer: Equatable, Sendable {
    public static let shareBackHint = "Then tap Share › Spoken Margins."

    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }

    public var message: String {
        "Spoken Margins couldn't read this page: \(reason)"
    }

    /// Why the article fallback failed, in the listener's words, from the page's HTTP status.
    public static func reason(forHTTPStatus status: Int) -> String {
        switch status {
        case 401, 403: "the site asked for a sign-in or refused the request (HTTP \(status))."
        case 404, 410: "the page wasn't found (HTTP \(status))."
        case 429: "the site is limiting requests right now (HTTP 429)."
        case 500...599: "the site had a server error (HTTP \(status))."
        default: "the site answered with HTTP \(status)."
        }
    }
}
