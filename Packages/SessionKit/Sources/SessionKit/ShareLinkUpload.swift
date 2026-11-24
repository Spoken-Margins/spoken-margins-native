import Foundation

// Share links, app side (#487). The phone seals the packet it already builds and a small preview under one fresh
// key (`ShareLinkSealing`), uploads both to `POST /api/v1/links`, and hands the share sheet
// `https://<host>/l/<id>#<key>`. The key never leaves the phone: it is the link's `#` part. The server stores bytes
// it can't read, so none of the caps below is a server-side check on content; they keep the preview small enough for
// the server's 16 KB limit and keep a link from quoting more than the owner allows (2026-10-20: no source text).
//
// Whether a build may make links at all is decided when the app is built (`SM_SHARE_LINK_CREATION`, project.yml),
// never here and never by the server. `links` in the server's config can only switch creation off.

/// The small preview sealed next to the packet, as the landing page reads it. Words only: the Margin texts, the
/// source title and show, and the source's public web page when it has one. No source text is quoted.
public struct ShareLinkPreview: Codable, Equatable, Sendable {
    public static let schema = "spokenmargins.link-preview.v1"

    public struct Source: Codable, Equatable, Sendable {
        public var title: String
        public var show: String?
        public var url: String?
    }

    public struct Margin: Codable, Equatable, Sendable {
        public var text: String
    }

    public var schema: String
    public var source: Source
    public var margins: [Margin]

    /// True when the source has no public web page (a pasted article, a PDF, an imported file, a private feed). The
    /// friend can't fetch the item from the link, so the share goes out as the link plus the `.spokenmargins`
    /// file in one message (owner, 2026-10-20). The file travels through the share sheet, never our server.
    public var needsCompanionFile: Bool { source.url == nil }
}

public enum ShareLinkPreviewBuilder {
    public enum Failure: Error, Equatable, Sendable {
        /// No Margin has words, so the landing page would show nothing.
        case nothingToSay
    }

    /// Each Margin's words are cut to this many Unicode scalars (the server counts scalars, not `Character`s).
    public static let maximumMarginScalars = 500
    static let maximumTitleScalars = 300
    static let maximumShowScalars = 200
    static let maximumURLCharacters = 2_000
    /// The server takes at most 16 KB of sealed preview; sealing adds an 8-byte header, a 12-byte nonce and a
    /// 16-byte tag.
    public static let maximumPreviewBytes = (16 << 10) - 36

    private static let audioOrFeedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "ogg", "oga", "opus", "flac", "mp4", "m4v", "xml", "rss", "atom", "json"
    ]
    /// A path part that names a feed anywhere in the path (`/feed/podcast/`, `/rss.php`), not only at its end.
    private static let feedComponents: Set<String> = ["feed", "feeds", "rss", "atom", "rss.php", "feed.php", "rss.xml", "feed.xml", "atom.xml", "podcast.xml", "podcast.rss"]

    /// Builds the preview. Margins past what fits in 16 KB are left out of the preview only: the packet still holds
    /// every Margin, so a friend with the app hears them all.
    public static func make(
        title: String,
        show: String?,
        pageURL: String?,
        enclosureURL: String?,
        marginTexts: [String]
    ) throws -> ShareLinkPreview {
        var margins = marginTexts
            .map { cut(trimmed($0), to: maximumMarginScalars) }
            .filter { !$0.isEmpty }
            .map { ShareLinkPreview.Margin(text: $0) }
        guard !margins.isEmpty else { throw Failure.nothingToSay }
        let cleanTitle = cut(trimmed(title), to: maximumTitleScalars)
        let cleanShow = show.map { cut(trimmed($0), to: maximumShowScalars) }.flatMap { $0.isEmpty ? nil : $0 }
        var preview = ShareLinkPreview(
            schema: ShareLinkPreview.schema,
            source: .init(
                title: cleanTitle.isEmpty ? "Shared Margins" : cleanTitle,
                show: cleanShow,
                url: publicPageURL(pageURL, enclosureURL: enclosureURL)
            ),
            margins: margins
        )
        while (try encoded(preview)).count > maximumPreviewBytes {
            guard margins.count > 1 else { throw Failure.nothingToSay }
            margins.removeLast()
            preview.margins = margins
        }
        return preview
    }

    public static func encoded(_ preview: ShareLinkPreview) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(preview)
    }

    /// The source's public web page, or nil. A page that holds an access secret, carries a query string or
    /// userinfo, is not https, or is really an audio file or a feed (a private feed can hold its token in the
    /// path) is left out; the link works without it. The one query kept is a known episode page's own key
    /// (`episodePageKeys`), alone.
    static func publicPageURL(_ page: String?, enclosureURL: String?) -> String? {
        guard let original = page.map(trimmed), !original.isEmpty, original.count <= maximumURLCharacters,
              ShareableLinkPolicy.shareableLink(original) != nil,
              let page = episodePageKeepingOnlyItsKey(original),
              let components = URLComponents(string: page),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.query == nil || episodePageKey(of: components) != nil else { return nil }
        if let enclosure = enclosureURL.map(trimmed), !enclosure.isEmpty, enclosure == page { return nil }
        let lowerHost = host.lowercased()
        if lowerHost.hasPrefix("feed.") || lowerHost.hasPrefix("feeds.") || lowerHost.contains("feedburner") { return nil }
        let pathParts = components.path.split(separator: "/").map { String($0).lowercased() }
        if pathParts.contains(where: feedComponents.contains) { return nil }
        let lastComponent = pathParts.last ?? ""
        if let dot = lastComponent.lastIndex(of: "."), audioOrFeedExtensions.contains(String(lastComponent[lastComponent.index(after: dot)...])) {
            return nil
        }
        return page
    }

    /// Pages that name their episode in the query, so "no query" would drop every one of them: an Apple Podcasts
    /// episode is `…/id916273527?i=1000543006547` (owner, 2026-11-17). Per host: the path it must be on (nil for
    /// any), the one key kept, and that key's value shape. Any other site's query is still left out.
    private struct EpisodePageKey: Sendable {
        let hosts: Set<String>
        let path: String?
        let name: String
        let isValue: @Sendable (Substring) -> Bool
    }

    private static let episodePageKeys: [EpisodePageKey] = [
        EpisodePageKey(hosts: ["podcasts.apple.com"], path: nil, name: "i") { value in
            (1...19).contains(value.count) && value.allSatisfy { $0.isASCII && $0.isNumber }
        },
        EpisodePageKey(hosts: ["www.youtube.com", "youtube.com", "m.youtube.com"], path: "/watch", name: "v") { value in
            value.count == 11 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        },
    ]

    /// The rule for this page's host and path, when its query holds exactly one well-formed episode key.
    private static func episodePageKey(of components: URLComponents) -> (rule: EpisodePageKey, value: Substring)? {
        guard let host = components.host?.lowercased(),
              let rule = episodePageKeys.first(where: { $0.hosts.contains(host) }),
              rule.path == nil || components.percentEncodedPath == rule.path else { return nil }
        let values = (components.percentEncodedQuery ?? "").split(separator: "&").compactMap { item -> Substring? in
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pair.count == 2 && pair[0] == Substring(rule.name) ? pair[1] : nil
        }
        guard values.count == 1, let value = values.first, rule.isValue(value) else { return nil }
        return (rule, value)
    }

    /// A known episode page rebuilt with its key alone (tracking items and the fragment dropped, the host lowercased);
    /// any other page unchanged; nil for a known episode host whose query is there but holds no single good key.
    private static func episodePageKeepingOnlyItsKey(_ page: String) -> String? {
        guard var components = URLComponents(string: page),
              let host = components.host?.lowercased(),
              episodePageKeys.contains(where: { $0.hosts.contains(host) }),
              components.percentEncodedQuery != nil || components.percentEncodedFragment != nil else { return page }
        components.percentEncodedFragment = nil
        guard components.percentEncodedQuery != nil else { return components.string }
        guard let key = episodePageKey(of: components) else { return nil }
        components.host = host
        components.percentEncodedQuery = "\(key.rule.name)=\(key.value)"
        return components.string
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cut(_ text: String, to scalars: Int) -> String {
        guard text.unicodeScalars.count > scalars else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.prefix(scalars))
        return trimmed(String(view))
    }
}

/// What the sender sees after asking for a link.
public enum ShareLinkResult: Equatable, Sendable {
    /// The link to share, with the day the server says it expires.
    case link(URL, expiresAt: String?)
    /// No link was made. The file share still works exactly as it does today.
    case useFile(ShareLinkFallback)
    /// The listener hasn't agreed to the upload yet (`ServerSendConsent`). Nothing was sealed or sent.
    case needsConsent
}

public enum ShareLinkFallback: Error, Equatable, Sendable {
    /// The server's `links` switch is off, or its config is missing or stale.
    case unavailable
    /// No Margin has words to show on the link's page.
    case nothingToSay
    /// The sealed packet is over the server's 20 MB limit.
    case tooLarge
    /// 429: one link at a time, or the hourly limit.
    case busy
    /// The phone could not reach the server.
    case offline
    /// The server answered something the app doesn't expect.
    case failed
    /// Link sharing is paused for this phone for a while (the strike ladder, #2239). The file share still works.
    case sharingPaused
    /// Link sharing has ended for this phone. The file share still works.
    case sharingEnded
    /// The server said the phone's clock is off (401 `clock_skew`), in refuse mode (#4134). Fixing the clock lets it pass.
    case clockWrong
    /// The sender check couldn't finish (Apple's call, the registration), in refuse mode. A later try may pass.
    case notVerified
    /// The sender check or the upload was refused in a way a retry won't fix (#4134): `permit_required`, a second
    /// `bad_permit`, a key the server keeps refusing.
    case cantVerify
    /// This phone can't attest, in refuse mode.
    case phoneCantMakeLinks
    /// The server's `links` switch is off for this build (`minimumBuild`).
    case updateNeeded

    /// The one line the sender sees, with the file share still on offer.
    public var message: String {
        switch self {
        case .tooLarge: "These Margins are too big for a link. Send them as a file instead?"
        case .nothingToSay: "None of these Margins has words yet, so a link would show nothing. Send them as a file instead?"
        case .busy: "Couldn't make a link right now. Try again in a little while, or send them as a file instead?"
        case .sharingPaused: "Sharing links is paused for a while. You can still send them as a file."
        case .sharingEnded: "Sharing links isn't available on this phone any more. You can still send them as a file."
        case .unavailable, .offline, .failed: "Links aren't available right now. Send as a file instead?"
        case .clockWrong: "Your iPhone's date and time look wrong, so a link can't be made. Turn on Set Automatically in Settings, General, Date & Time, then try again. You can still send them as a file."
        case .notVerified: "This iPhone couldn't be checked for links just now. Try again in a few minutes, or send them as a file."
        case .cantVerify: "Links can't be made from this iPhone right now. You can still send them as a file."
        case .phoneCantMakeLinks: "This iPhone can't make links. You can still send them as a file."
        case .updateNeeded: "Update Spoken Margins to share links. You can still send them as a file."
        }
    }

    /// What "Share link" does after this line (#4134): a refusal that won't pass on a retry never invites one.
    public var shareLinkAfterwards: ShareLinkButtonAfterFallback {
        switch self {
        case .cantVerify: .disabledUntilReopened
        case .phoneCantMakeLinks: .disabled
        case .updateNeeded: .hidden
        default: .enabled
        }
    }
}

/// The "Share link" button after a line (#4134 Design, section 2).
public enum ShareLinkButtonAfterFallback: Equatable, Sendable {
    /// Tapping again may work (fixing the clock, a few minutes, a smaller selection).
    case enabled
    /// Not again on this sheet; a new sheet may try once more.
    case disabledUntilReopened
    /// Not on this phone.
    case disabled
    /// Not in this build: the button is hidden and the line says to update.
    case hidden

    /// Whether the sender can tap "Share link" while this is on show.
    public var allowsShareLink: Bool { self == .enabled }
}

/// Refuse mode (#4134): what a sender check with no standing does to the link. Off, a fault makes the link with no
/// permit, unattributed, as the owner's call of 2026-11-12 says for as long as the App Attest entitlement isn't shipped
/// and no real phone is accepted (#1593). On, a fault stops the link with its own line. The switch ships in a build
/// (`SMShareLinkRefuseUnchecked` in Info.plist, Release only), never from the server or the device; the key is absent
/// today, which is off. The server operator's 503 `disabled` keeps meaning "make the link unattributed" in both modes.
public struct ShareLinkFaultPolicy: Equatable, Sendable {
    public static let infoPlistKey = "SMShareLinkRefuseUnchecked"
    public static let off = ShareLinkFaultPolicy(refusesUnchecked: false)
    public static let refuse = ShareLinkFaultPolicy(refusesUnchecked: true)

    public var refusesUnchecked: Bool

    public init(refusesUnchecked: Bool) {
        self.refusesUnchecked = refusesUnchecked
    }

    /// The build's switch: on when the Info.plist key is the Boolean true, or `YES` / `true` as a build setting writes it
    /// (`SMShareLinkRefuseUnchecked: $(SM_SHARE_LINK_REFUSE_UNCHECKED)`, set in Release only). Anything else is off.
    public static func fromInfoPlist(_ info: [String: Any]?) -> ShareLinkFaultPolicy {
        let value = info?[infoPlistKey]
        if let flag = value as? Bool { return ShareLinkFaultPolicy(refusesUnchecked: flag) }
        let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        return ShareLinkFaultPolicy(refusesUnchecked: text == "yes" || text == "true")
    }

    /// The line for an unchecked sender, or nil to make the link without a permit.
    public func fallback(for reason: ShareLinkUncheckedReason) -> ShareLinkFallback? {
        if reason == .operatorDisabled { return nil }
        guard refusesUnchecked else { return nil }
        switch reason {
        case .cannotAttest: return .phoneCantMakeLinks
        case .attestFailed, .invalidAssertionOnce: return .notVerified
        case .clockSkew: return .clockWrong
        case .serverError: return .unavailable
        case .registrationWaiting, .unknownKey, .invalidAssertion, .missingAssertion, .rejected: return .cantVerify
        case .operatorDisabled: return nil
        }
    }
}

/// Posts one multipart body. The real transport is host-pinned, ephemeral and follows no redirect; tests pass a
/// recording one.
public typealias ShareLinkPost = @Sendable (_ url: URL, _ contentType: String, _ body: Data) async throws -> (status: Int, body: Data)

/// The same, with the headers the upload sets besides its content type (today: the sender check's permit).
public typealias ShareLinkPostWithHeaders = @Sendable (_ url: URL, _ contentType: String, _ headers: [String: String], _ body: Data) async throws -> (status: Int, body: Data)

public struct ShareLinkClient: Sendable {
    public static let linksPath = "/api/v1/links"
    /// Carries the one-use permit from the sender check (`HeaderLinkPermit` in the server's sender.go).
    public static let permitHeader = "X-SM-Link-Permit"
    /// The server's limit on the sealed packet.
    public static let maximumSealedPacketBytes = 20 << 20
    private static let maximumPreviewPartBytes = 16 << 10

    private let server: @Sendable (String) -> URL
    private let post: ShareLinkPostWithHeaders
    private let senderCheck: (@Sendable () async -> ShareLinkSenderCheckOutcome)?
    private let takedownNoticeSeen: @Sendable () -> Void
    private let makeKey: @Sendable () -> ShareLinkSealing.Key
    private let hasConsent: @Sendable () -> Bool

    /// `consent` has no default on purpose: a caller must say where the listener's agreement is read from, so no
    /// upload path can skip it (#2842).
    ///
    /// `senderCheck` asks the server for the install's standing and a permit before anything is sealed (#2239). With
    /// none, the link is made as it always was, with no identity attached. `takedownNotice` is called when the
    /// server says a link this install made was taken down, so the screen can say so once.
    public init(
        server: @escaping @Sendable (String) -> URL = { ProductServer.url(path: $0) },
        key: @escaping @Sendable () -> ShareLinkSealing.Key = { ShareLinkSealing.Key.random() },
        consent: @escaping @Sendable () -> Bool,
        senderCheck: (@Sendable () async -> ShareLinkSenderCheckOutcome)? = nil,
        takedownNotice: @escaping @Sendable () -> Void = {},
        post: @escaping ShareLinkPostWithHeaders
    ) {
        self.server = server
        self.makeKey = key
        self.hasConsent = consent
        self.senderCheck = senderCheck
        self.takedownNoticeSeen = takedownNotice
        self.post = post
    }

    public init(
        server: @escaping @Sendable (String) -> URL = { ProductServer.url(path: $0) },
        key: @escaping @Sendable () -> ShareLinkSealing.Key = { ShareLinkSealing.Key.random() },
        consent: @escaping @Sendable () -> Bool,
        post: @escaping ShareLinkPost
    ) {
        self.init(server: server, key: key, consent: consent, post: { url, contentType, _, body in
            try await post(url, contentType, body)
        })
    }

    /// Seals and uploads. Never throws: every way it can fail comes back as `.useFile`, so the sender screen has
    /// one thing to handle. Nothing is sealed or sent unless the listener has agreed and `linksState` is on.
    /// `faultPolicy` decides what a sender check with no standing does (#4134); the app passes its build's switch.
    public func makeLink(
        packet: Data, preview: ShareLinkPreview, linksState: ServerFeatureState, faultPolicy: ShareLinkFaultPolicy = .off
    ) async -> ShareLinkResult {
        guard hasConsent() else { return .needsConsent }
        if case .off(.buildTooOld) = linksState { return .useFile(.updateNeeded) }
        guard linksState.isOn else { return .useFile(.unavailable) }
        // Who is asking, before the packet is read or sealed: a paused or ended sender makes no link, and the
        // permit the server hands back is what ties this link to the install for the strike ladder.
        var permit: String?
        switch await askSender(faultPolicy) {
        case .proceed(let granted): permit = granted
        case .stop(let fallback): return .useFile(fallback)
        }
        let sealed: ShareLinkSealing.SealedLink
        let key = makeKey()
        do {
            let previewBytes = try ShareLinkPreviewBuilder.encoded(preview)
            sealed = try ShareLinkSealing.seal(packet: packet, preview: previewBytes, key: key)
        } catch {
            return .useFile(.failed)
        }
        // The size is known before anything leaves the phone.
        guard sealed.packet.count <= Self.maximumSealedPacketBytes else { return .useFile(.tooLarge) }
        guard sealed.preview.count <= Self.maximumPreviewPartBytes else { return .useFile(.failed) }

        let boundary = "SM-" + UUID().uuidString
        let body = Self.multipartBody(boundary: boundary, preview: sealed.preview, packet: sealed.packet)
        let contentType = "multipart/form-data; boundary=\(boundary)"
        var response: (status: Int, body: Data)
        do {
            response = try await post(server(Self.linksPath), contentType, permit.map { [Self.permitHeader: $0] } ?? [:], body)
            // A permit can expire between the check and the upload (ten minutes, or a server restart): one fresh check
            // and one more upload. A second `bad_permit` is final (#4134).
            if response.status == 403, AttestedServerClient.errorCode(response.body) == "bad_permit", senderCheck != nil {
                switch await askSender(faultPolicy) {
                case .proceed(let granted): permit = granted
                case .stop(let fallback): return .useFile(fallback)
                }
                response = try await post(server(Self.linksPath), contentType, permit.map { [Self.permitHeader: $0] } ?? [:], body)
                if response.status == 403, AttestedServerClient.errorCode(response.body) == "bad_permit" { return .useFile(.cantVerify) }
            }
        } catch {
            return .useFile(.offline)
        }
        switch response.status {
        case 201:
            guard let created = try? JSONDecoder().decode(Created.self, from: response.body),
                  Self.isLinkPath(created.path),
                  let link = ShareLinkSealing.linkURL(base: server(created.path), key: key) else { return .useFile(.failed) }
            return .link(link, expiresAt: created.expiresAt)
        case 403:
            // The permit from the sender check: spent, expired (ten minutes, or a server restart) or paused in between.
            switch AttestedServerClient.errorCode(response.body) {
            case "sharing_paused": return .useFile(.sharingPaused)
            // `permit_required` comes only once the server requires permits; a retry won't bring one (#4134).
            case "bad_permit", "permit_required": return .useFile(.cantVerify)
            default: return .useFile(.failed)
            }
        case 413: return .useFile(.tooLarge)
        case 429: return .useFile(.busy)
        case 503: return .useFile(.unavailable)
        default: return .useFile(.failed)
        }
    }

    private enum SenderAnswer {
        case proceed(permit: String?)
        case stop(ShareLinkFallback)
    }

    /// The sender check, read under `policy`. No check configured makes the link as it always was, with no identity.
    private func askSender(_ policy: ShareLinkFaultPolicy) async -> SenderAnswer {
        guard let senderCheck else { return .proceed(permit: nil) }
        switch await senderCheck() {
        case .notChecked(let reason):
            if let fallback = policy.fallback(for: reason) { return .stop(fallback) }
            return .proceed(permit: nil)
        case .failed(let fallback): return .stop(fallback)
        case .standing(let standing):
            if standing.hasTakedownNotice { takedownNoticeSeen() }
            if standing.sharingEnded { return .stop(.sharingEnded) }
            guard let granted = standing.permit else { return .stop(.sharingPaused) }
            return .proceed(permit: granted)
        }
    }

    private struct Created: Decodable {
        var path: String
        var expiresAt: String?
    }

    /// `/l/<id>` with the id the server mints and the app opens: 32 lowercase hex characters. Anything else is
    /// never turned into a link the sender would send.
    static func isLinkPath(_ path: String) -> Bool {
        guard path.hasPrefix("/l/") else { return false }
        let id = path.dropFirst(3)
        return id.utf8.count == ShareLinkURL.idLength && id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    /// Exactly two parts, `preview` first and `packet` second, both opaque.
    static func multipartBody(boundary: String, preview: Data, packet: Data) -> Data {
        var body = Data()
        func part(_ name: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        part("preview", preview)
        part("packet", packet)
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}

/// Which link request's answer may still reach the sender screen. A link takes seconds to make; if the listener goes
/// back to the selection or changes it meanwhile, the answer is for a packet that no longer matches the screen, and
/// must neither open a share sheet nor show a line (#3751 audit). `begin` hands out a ticket, `cancel` voids every
/// ticket out, and only the newest ticket is accepted.
public struct ShareLinkRequests: Sendable, Equatable {
    public struct Ticket: Sendable, Equatable {
        fileprivate let number: Int
    }

    private var newest = 0

    public init() {}

    public mutating func begin() -> Ticket {
        newest += 1
        return Ticket(number: newest)
    }

    public mutating func cancel() {
        newest += 1
    }

    public func accepts(_ ticket: Ticket) -> Bool {
        ticket.number == newest
    }
}
