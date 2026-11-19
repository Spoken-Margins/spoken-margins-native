import Foundation

/// A link shortener's address (`https://t.co/...`) names a redirect, not an article (#4633).
///
/// The article reader loads a page in a web view, which presents itself as a browser. A shortener such as t.co
/// answers a browser with a small page of its own (a `<meta http-equiv="refresh">` and a script that calls
/// `location.replace`) and answers anything else with a plain 301. The reader finished on that small page, which
/// has no article text, and said "no article text was found" for a link Safari opens without trouble.
///
/// So a shortener's address is followed first, by a plain request to the shortener only: https, no cookies, five
/// hops at most, a capped body. The destination is then read as any pasted article link is, so it is the page that
/// is fetched with a browser's identity, and the item names the destination, not the shortener.
public enum ShortLink {
    /// Shorteners whose addresses are followed. A host not listed here is read as given.
    public static let hosts: Set<String> = [
        "t.co", "bit.ly", "lnkd.in", "buff.ly", "ow.ly", "tinyurl.com", "trib.al",
    ]

    public static func isShortLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Where a shortener's own page sends the browser, read from its `<meta http-equiv="refresh">` or its
    /// `location.replace("...")` call. Nil when the page names no https address.
    public static func destination(fromInterstitial html: String, base: URL) -> URL? {
        let candidates = [
            #"(?is)<meta\b[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["'][^"']*?url\s*=\s*([^"'>\s]+)"#,
            #"(?is)<meta\b[^>]*content\s*=\s*["'][^"']*?url\s*=\s*([^"'>\s]+)["'][^>]*http-equiv\s*=\s*["']?refresh"#,
            #"(?is)\blocation\.(?:replace|assign)\(\s*["']([^"']+)["']\s*\)"#,
            #"(?is)\blocation(?:\.href)?\s*=\s*["']([^"']+)["']"#,
        ]
        for pattern in candidates {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let raw = String(html[range])
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\u0026", with: "&")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  url.scheme?.lowercased() == "https", url.host != nil else { continue }
            return url
        }
        return nil
    }
}

/// One answer from a shortener. A redirect is reported, never taken.
public struct ShortLinkHop: Equatable, Sendable {
    public var status: Int
    /// The `Location` of a 3xx answer, already resolved against the request address.
    public var location: URL?
    /// The start of a 200 answer's body, where a shortener's own page keeps its redirect.
    public var bodyPrefix: String

    public init(status: Int, location: URL? = nil, bodyPrefix: String = "") {
        self.status = status
        self.location = location
        self.bodyPrefix = bodyPrefix
    }
}

/// Follows a shortener's address to the first address that isn't a shortener's.
public struct ShortLinkResolver: Sendable {
    public static let maximumHops = 5
    public typealias Fetch = @Sendable (URL) async throws -> ShortLinkHop

    private let fetch: Fetch

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// The address to read as the article: `url` itself unless it is a shortener's. Any failure (offline, a timeout,
    /// a non-redirect answer, an address that isn't https) stops at the last good address, so the reader still
    /// meets its own errors and the listener still gets its Open in Safari offer. `followed` lists each shortener
    /// host asked.
    public func resolve(_ url: URL) async -> (url: URL, followed: [String]) {
        var current = url
        var followed: [String] = []
        for _ in 0..<Self.maximumHops {
            guard ShortLink.isShortLink(current), let host = current.host?.lowercased() else { break }
            guard let hop = try? await fetch(current), !Task.isCancelled else { break }
            followed.append(host)
            let next: URL?
            switch hop.status {
            case 301, 302, 303, 307, 308:
                next = hop.location
            case 200:
                next = ShortLink.destination(fromInterstitial: hop.bodyPrefix, base: current)
            default:
                next = nil
            }
            guard let next, next.scheme?.lowercased() == "https", next.host != nil, next != current else { break }
            current = next
        }
        return (current, followed)
    }
}

/// Reads an article from the address a shortener points to. Wraps the app's readable-page extractor, so every
/// way an article is added (a pasted link, a shared link, a feed entry, a packet's article) gets the same
/// treatment, and runs only when one of them asks for a page: never in the background of its own.
@MainActor
public final class ShortLinkFollowingExtractor: ReadablePageExtracting {
    private let inner: any ReadablePageExtracting
    private let resolver: ShortLinkResolver
    private var followedHosts: [String] = []

    public init(wrapping inner: any ReadablePageExtracting, resolver: ShortLinkResolver) {
        self.inner = inner
        self.resolver = resolver
    }

    public var lastExtractor: String? { inner.lastExtractor }

    public var contactedHosts: [String] {
        var seen = Set<String>()
        return (followedHosts + inner.contactedHosts).filter { seen.insert($0).inserted }
    }

    public func extract(url: URL) async throws -> BrowserTextHandoff {
        let resolved = await resolver.resolve(url)
        followedHosts = resolved.followed
        return try await inner.extract(url: resolved.url)
    }
}

#if !canImport(FoundationNetworking)
/// The live request behind `ShortLinkResolver`: anonymous, like the app's other requests to a publisher. An
/// ephemeral session with cookies, cache and credentials off, no redirect taken by the session, and a body read
/// only up to a small cap.
public enum ShortLinkTransport {
    static let maximumBodyBytes = 64 * 1_024

    public static let hop: ShortLinkResolver.Fetch = { url in
        try await hop(url, configuration: configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return configuration
    }

    static func hop(_ url: URL, configuration: URLSessionConfiguration) async throws -> ShortLinkHop {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        // A plain client, not a browser: a shortener answers one with a redirect it can read.
        request.setValue("SpokenMargins/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var body = Data()
        if http.statusCode == 200 {
            for try await byte in bytes {
                try Task.checkCancellation()
                body.append(byte)
                if body.count >= maximumBodyBytes { break }
            }
        }
        let location = http.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        return ShortLinkHop(
            status: http.statusCode, location: location, bodyPrefix: String(decoding: body, as: UTF8.self))
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
#endif
