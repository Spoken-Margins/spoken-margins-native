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
    /// path) is left out; the link works without it.
    static func publicPageURL(_ page: String?, enclosureURL: String?) -> String? {
        guard let page = page.map(trimmed), !page.isEmpty, page.count <= maximumURLCharacters,
              ShareableLinkPolicy.shareableLink(page) != nil,
              let components = URLComponents(string: page),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
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

    /// The one line the sender sees, with the file share still on offer.
    public var message: String {
        switch self {
        case .tooLarge: "These Margins are too big for a link. Send them as a file instead?"
        case .nothingToSay: "None of these Margins has words yet, so a link would show nothing. Send them as a file instead?"
        case .busy: "Couldn't make a link right now. Try again in a little while, or send them as a file instead?"
        case .unavailable, .offline, .failed: "Links aren't available right now. Send as a file instead?"
        }
    }
}

/// Posts one multipart body. The real transport is host-pinned, ephemeral and follows no redirect; tests pass a
/// recording one.
public typealias ShareLinkPost = @Sendable (_ url: URL, _ contentType: String, _ body: Data) async throws -> (status: Int, body: Data)

public struct ShareLinkClient: Sendable {
    public static let linksPath = "/api/v1/links"
    /// The server's limit on the sealed packet.
    public static let maximumSealedPacketBytes = 20 << 20
    private static let maximumPreviewPartBytes = 16 << 10

    private let server: @Sendable (String) -> URL
    private let post: ShareLinkPost
    private let makeKey: @Sendable () -> ShareLinkSealing.Key

    public init(
        server: @escaping @Sendable (String) -> URL = { ProductServer.url(path: $0) },
        key: @escaping @Sendable () -> ShareLinkSealing.Key = { ShareLinkSealing.Key.random() },
        post: @escaping ShareLinkPost
    ) {
        self.server = server
        self.makeKey = key
        self.post = post
    }

    /// Seals and uploads. Never throws: every way it can fail comes back as `.useFile`, so the sender screen has
    /// one thing to handle. Nothing is sealed or sent unless `linksState` is on.
    public func makeLink(packet: Data, preview: ShareLinkPreview, linksState: ServerFeatureState) async -> ShareLinkResult {
        guard linksState.isOn else { return .useFile(.unavailable) }
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
        let response: (status: Int, body: Data)
        do {
            response = try await post(server(Self.linksPath), "multipart/form-data; boundary=\(boundary)", body)
        } catch {
            return .useFile(.offline)
        }
        switch response.status {
        case 201:
            guard let created = try? JSONDecoder().decode(Created.self, from: response.body),
                  Self.isLinkPath(created.path),
                  let link = ShareLinkSealing.linkURL(base: server(created.path), key: key) else { return .useFile(.failed) }
            return .link(link, expiresAt: created.expiresAt)
        case 413: return .useFile(.tooLarge)
        case 429: return .useFile(.busy)
        case 503: return .useFile(.unavailable)
        default: return .useFile(.failed)
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
