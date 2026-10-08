import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SessionKit

// B2 M1: any Substack link (post, home page, custom domain, share link, profile, /feed) resolves
// to its publication's feed. Ported from research/B2/substack_resolver.py and tested against the
// same recorded responses.
//
// Why it doesn't need the post to be in the feed: a /p/<slug> page that Substack serves from
// origin X belongs to the publication whose feed is X/feed. Old posts (outside the 20-item feed)
// and links with ?utm_ or ?r= therefore resolve the same way as a clean, recent link.
//
// Requests:
// - A custom domain or <name>.substack.com: one GET of <origin>/feed, which must be served by
//   Substack. No page is downloaded, so large home pages don't matter. When the origin has no
//   feed (an apex redirector, or a subdomain that moved), the link itself is followed once.
// - substack.com/home/post/p-ID, /@handle/p-ID, /inbox/post/ID, /app-link/post: one GET of the
//   link (Substack redirects it to the post), then <origin>/feed.
// - open.substack.com/pub/<name>/...: names the publication directly.
// - A substack.com/@handle profile: its primary publication, never presented as certain.
// A non-Substack link costs one GET of <origin>/feed; generic discovery then handles it.

public enum SubstackFetchKind: String, Sendable {
    case feed
    case html
}

/// The final response after redirects, as `URLSession` hands it back.
public struct SubstackFetchResponse: Sendable {
    public var url: URL
    public var status: Int
    /// Header names in lowercase.
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, status: Int, headers: [String: String], body: Data) {
        self.url = url
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct SubstackPublication: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case publication = "substack_publication"
        case podcastFeed = "substack_podcast_feed"
        /// A subscriber's paid feed link. Never leaves the device (I1, #168).
        case privateFeed = "substack_private_feed"
    }

    public var kind: Kind
    public var feedURL: String
    public var publicationURL: String?
    public var feed: ParsedFeed
    public var confidence: Double
    /// Evidence for the listener and diagnostics. Private tokens are redacted.
    public var reason: String
    public var isPrivate: Bool

    /// A profile names only its primary publication, so it gets "Is this it?" (I1).
    public var isCertain: Bool { confidence >= 0.9 }
}

public struct SubstackPublicationResolver: Sendable {
    /// Fetches `url`, following at most five https redirects, and returns the final response.
    /// Throws when the request fails or a redirect is refused.
    public typealias Fetch = @Sendable (URL, SubstackFetchKind) async throws -> SubstackFetchResponse

    private let fetch: Fetch
    private let parser = FeedParser()

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// The publication feed for `link`, or nil when it isn't a Substack (generic discovery keeps it).
    public func resolve(_ link: String) async -> SubstackPublication? {
        await resolveExplained(link).publication
    }

    /// The same, with a short trace of each step for diagnostics (#244: a failed Follow said only
    /// "FollowedSourceError"). The trace names hosts and statuses, never a full link or a token.
    public func resolveExplained(_ link: String) async -> (publication: SubstackPublication?, trace: [String]) {
        let trace = Trace()
        let publication = await resolve(link, trace: trace)
        return (publication, trace.steps)
    }

    private func resolve(_ link: String, trace: Trace) async -> SubstackPublication? {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            trace.add("not an http(s) link")
            return nil
        }
        if let privateFeed = Self.canonicalPrivateFeedURL(raw) {
            return await feedLink(privateFeed, isPrivate: true, trace: trace)
        }
        if Self.matches(raw, Self.publicPodcastFeed) {
            return await feedLink(raw, isPrivate: false, trace: trace)
        }
        // Substack serves everything over https; an http link is upgraded, never fetched as http.
        var upgraded = components
        upgraded.scheme = "https"
        upgraded.host = host
        upgraded.fragment = nil
        guard let httpsURL = upgraded.url else { return nil }
        let path = components.path
        var evidence = ["input \(Self.redact(Self.stripTracking(raw)))"]

        if host == "open.substack.com", let name = Self.firstCapture(path, #"^/pub/([A-Za-z0-9-]+)(?:/|$)"#) {
            evidence.append("open.substack.com share link names publication '\(name.lowercased())'")
            return await confirm(origin: "https://\(name.lowercased()).substack.com", evidence: evidence, confidence: 0.95, trace: trace).publication
        }
        if Self.substackAppHosts.contains(host), let handle = Self.firstCapture(path, #"^/@([A-Za-z0-9_.-]+)/?$"#) {
            return await profile(handle: handle, evidence: evidence, trace: trace)
        }
        if !Self.platformHosts.contains(host) {
            if host.hasSuffix(".substack.com") {
                evidence.append("Substack subdomain '\(host.split(separator: ".")[0])'")
            }
            switch await confirm(origin: Self.origin(of: httpsURL), evidence: evidence, confidence: 0.95, requiresSubstack: true, trace: trace) {
            case .found(let publication):
                return publication
            case .notSubstack:
                // The origin serves its own feed and it isn't Substack's.
                return nil
            case .unavailable:
                // No feed at this origin: a redirector (apex to www), or a subdomain whose
                // publication moved (redirects to a profile). Follow the link itself once.
                break
            }
        }

        // substack.com post links and the fallback above: Substack redirects to the post or the
        // publication, and the final URL names it. The query is kept, because app-link needs
        // publication_id and post_id to redirect.
        guard let response = await fetchTraced(httpsURL, .html, label: "page on \(host)", trace: trace) else { return nil }
        guard response.status == 200 else {
            trace.add("page on \(host): status \(response.status)")
            return nil
        }
        guard Self.servedBySubstack(response) else {
            trace.add("page on \(host): not served by Substack")
            return nil
        }
        let finalHost = response.url.host?.lowercased() ?? ""
        if Self.substackAppHosts.contains(finalHost),
           let handle = Self.firstCapture(response.url.path, #"^/@([A-Za-z0-9_.-]+)/?$"#) {
            evidence.append("redirected to profile @\(handle)")
            return await profile(handle: handle, evidence: evidence, trace: trace)
        }
        // A Substack app page that isn't a publication (notes, sign-in), or no progress.
        guard !Self.platformHosts.contains(finalHost), finalHost != host else {
            trace.add("page on \(host): no redirect to a publication")
            return nil
        }
        evidence.append("redirected to \(Self.stripTracking(response.url.absoluteString))")
        return await confirm(origin: Self.origin(of: response.url), evidence: evidence, confidence: 0.95, requiresSubstack: true, trace: trace).publication
    }

    /// Per-call trace of what each step saw.
    private final class Trace: @unchecked Sendable {
        private(set) var steps: [String] = []
        func add(_ step: String) { steps.append(step) }
    }

    private func fetchTraced(_ url: URL, _ kind: SubstackFetchKind, label: String, trace: Trace) async -> SubstackFetchResponse? {
        do {
            return try await fetch(url, kind)
        } catch {
            let nsError = error as NSError
            trace.add("\(label): fetch failed (\(nsError.domain) \(nsError.code))")
            return nil
        }
    }

    // MARK: - Steps

    private enum Confirmation {
        case found(SubstackPublication)
        case notSubstack
        case unavailable

        var publication: SubstackPublication? {
            if case .found(let publication) = self { return publication }
            return nil
        }
    }

    private func confirm(
        origin: String,
        evidence: [String],
        confidence: Double,
        requiresSubstack: Bool = false,
        trace: Trace
    ) async -> Confirmation {
        let label = "\(origin.replacingOccurrences(of: "https://", with: ""))/feed"
        guard let feedURL = URL(string: "\(origin)/feed"),
              let response = await fetchTraced(feedURL, .feed, label: label, trace: trace) else { return .unavailable }
        guard response.status == 200 else {
            trace.add("\(label): status \(response.status)")
            return .unavailable
        }
        if requiresSubstack, !Self.feedIsFromSubstack(response) {
            trace.add("\(label): not Substack")
            return .notSubstack
        }
        let parsed: ParsedFeed
        do {
            parsed = try parser.parse(data: response.body, contentType: response.header("content-type"))
        } catch {
            trace.add("\(label): feed didn't parse (\(error))")
            return .unavailable
        }
        trace.add("\(label): Substack feed, \(parsed.items.count) items")
        let finalFeed = Self.stripTracking(response.url.absoluteString)
        var feed = parsed
        feed.feedURL = finalFeed
        let reason = (evidence + ["feed \(finalFeed) parsed (\(parsed.items.count) items)"]).joined(separator: "; ")
        return .found(SubstackPublication(
            kind: .publication,
            feedURL: finalFeed,
            publicationURL: URL(string: finalFeed).map(Self.origin(of:)),
            feed: feed,
            confidence: confidence,
            reason: reason,
            isPrivate: false
        ))
    }

    private func profile(handle: String, evidence: [String], trace: Trace) async -> SubstackPublication? {
        guard let url = URL(string: "https://substack.com/@\(handle)"),
              let response = await fetchTraced(url, .html, label: "profile @\(handle)", trace: trace) else { return nil }
        guard response.status == 200 else {
            trace.add("profile @\(handle): status \(response.status)")
            return nil
        }
        let body = String(decoding: response.body, as: UTF8.self)
        guard let match = body.range(
            of: #"primaryPublication\\":\{\\"id\\":\d+,\\"subdomain\\":\\"([a-z0-9-]+)\\""#,
            options: .regularExpression
        ), let subdomain = Self.firstCapture(String(body[match]), #"subdomain\\":\\"([a-z0-9-]+)\\""#) else {
            trace.add("profile @\(handle): no primary publication")
            return nil
        }
        let window = String(body[match.upperBound...].prefix(400))
        let custom = Self.firstCapture(window, #"\\"custom_domain\\":\\"([^\\"]+)\\""#)
        let origin = custom.map { "https://\($0)" } ?? "https://\(subdomain).substack.com"
        // A writer can run several publications; the profile names only the primary one.
        let named = evidence + ["profile @\(handle): primary publication '\(subdomain)'"]
        return await confirm(origin: origin, evidence: named, confidence: 0.8, trace: trace).publication
    }

    /// A Substack podcast feed link pasted as is: public, or a subscriber's private one.
    private func feedLink(_ link: String, isPrivate: Bool, trace: Trace) async -> SubstackPublication? {
        let label = isPrivate ? "private feed link" : "podcast feed link"
        guard let url = URL(string: link),
              let response = await fetchTraced(url, .feed, label: label, trace: trace) else { return nil }
        guard response.status == 200,
              var parsed = try? parser.parse(data: response.body, contentType: response.header("content-type")) else {
            trace.add("\(label): status \(response.status) or didn't parse")
            return nil
        }
        parsed.feedURL = link
        let audio = parsed.items.filter { $0.audioURL != nil }.count
        return SubstackPublication(
            kind: isPrivate ? .privateFeed : .podcastFeed,
            feedURL: link,
            publicationURL: nil,
            feed: parsed,
            confidence: 1,
            reason: "\(label) \(Self.redact(link)); parsed (\(parsed.items.count) items, \(audio) with audio)",
            isPrivate: isPrivate
        )
    }

    // MARK: - Evidence

    /// Hosts on substack.com that are Substack's own app, not a publication.
    static let platformHosts: Set<String> = [
        "substack.com", "www.substack.com", "open.substack.com", "api.substack.com",
        "support.substack.com", "cdn.substack.com", "substackcdn.com"
    ]
    private static let substackAppHosts: Set<String> = ["substack.com", "www.substack.com"]

    private static let trackingQueryName = #"^(utm_[a-z_]+|r|ref|s|triedRedirect|showWelcomeOnShare|publication_id|post_id|isFreemail|token|sd|next|action|open|source|img|share)$"#
    /// The path of a private feed link, with the host it is tied to (nil: any host). A trailing slash is allowed.
    private static let privateFeedPaths: [(host: String?, path: String)] = [
        // The paid podcast feed a subscriber copies from their subscription page.
        (host: "api.substack.com", path: #"^/feed/podcast/\d+/private/[^/]+\.rss/?$"#),
        // A per-subscriber text feed path from third-party guides; unconfirmed, but it would carry a token.
        (host: nil, path: #"^/feed/private/[^/]+/?$"#)
    ]
    /// A publication's public podcast feed (where <origin>/feed/podcast redirects).
    private static let publicPodcastFeed = #"^https://api\.substack\.com/feed/podcast/\d+\.rss$"#

    /// True for a private feed link whatever follows it: a query (an email's tracking parameters),
    /// a fragment, a trailing slash, or `http://` (#1051).
    public static func isPrivateFeedURL(_ link: String) -> Bool {
        canonicalPrivateFeedURL(link) != nil
    }

    /// The link to fetch and keep for a private feed: https, without the query, fragment or trailing
    /// slash that came with the copied link (the token is in the path), or nil when `link` is not a
    /// private feed link. Substack serves everything over https, so an `http://` link is upgraded,
    /// never fetched as http, where its token would cross the network in the clear.
    public static func canonicalPrivateFeedURL(_ link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let path = components.percentEncodedPath
        let hostOnly = components.user == nil && components.password == nil && components.port == nil
        guard privateFeedPaths.contains(where: { entry in
            guard let entryHost = entry.host else { return matches(path, entry.path) }
            return hostOnly && host == entryHost && matches(path, entry.path)
        }) else { return nil }
        components.scheme = "https"
        components.host = host
        if scheme == "http", components.port == 80 { components.port = nil }
        components.query = nil
        components.fragment = nil
        if path.hasSuffix("/") { components.percentEncodedPath = String(path.dropLast()) }
        return components.string
    }

    /// A private feed link without its token, for reasons, logs and diagnostics.
    public static func redact(_ link: String) -> String {
        link.replacingOccurrences(of: #"/private/[^/]+"#, with: "/private/…", options: [.regularExpression, .caseInsensitive])
    }

    /// Drops tracking and share parameters and the fragment; keeps any meaningful query.
    public static func stripTracking(_ link: String) -> String {
        guard var components = URLComponents(string: link) else { return link }
        let kept = (components.queryItems ?? []).filter { !matches($0.name, trackingQueryName, caseInsensitive: true) }
        components.queryItems = kept.isEmpty ? nil : kept
        components.fragment = nil
        return components.string ?? link
    }

    private static func servedBySubstack(_ response: SubstackFetchResponse) -> Bool {
        if response.header("x-served-by")?.lowercased() == "substack" || response.header("x-sub") != nil {
            return true
        }
        // A proxy in front of a custom domain can strip the headers; fall back to page markers.
        let body = String(decoding: response.body, as: UTF8.self)
        return body.contains("substackcdn.com")
            && body.range(of: #"<link[^>]*alternate[^>]*href="/feed""#, options: .regularExpression) != nil
    }

    private static func feedIsFromSubstack(_ response: SubstackFetchResponse) -> Bool {
        if response.header("x-served-by")?.lowercased() == "substack" || response.header("x-sub") != nil {
            return true
        }
        return String(decoding: response.body.prefix(4096), as: UTF8.self).contains("<generator>Substack</generator>")
    }

    private static func origin(of url: URL) -> String {
        "https://\(url.host?.lowercased() ?? "")"
    }

    private static func matches(_ value: String, _ pattern: String, caseInsensitive: Bool = true) -> Bool {
        value.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
    }

    private static func firstCapture(_ value: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

// Seam I1: the Substack resolver as a `SourceResolver`, so `SourceResolverRegistry` runs it
// alongside the others. Origin evidence is `exact`; a profile's primary publication is `likely`
// ("Is this it?"). A private feed stays private (#168), and its id carries no token.
extension SubstackPublicationResolver: SourceResolver {
    public var id: String { "substack" }

    public func canResolve(_ input: SourceResolutionInput) -> Bool {
        guard case .link(let link) = input,
              let scheme = URLComponents(string: link)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public func resolve(_ input: SourceResolutionInput) async throws -> [SourceCandidate] {
        guard case .link(let link) = input, let publication = await resolve(link) else { return [] }
        let isPodcast = publication.feed.items.contains { $0.audioURL != nil }
        return [SourceCandidate(
            id: "substack:\(Self.redact(publication.feedURL))",
            kind: isPodcast ? .podcastFeed : .articleFeed,
            contentKind: isPodcast ? .podcast : .newsletter,
            title: publication.feed.title,
            websiteURL: publication.publicationURL,
            feed: SourceCandidateFeed(url: publication.feedURL, isPrivate: publication.isPrivate),
            confidence: publication.isCertain ? .exact : .likely,
            reason: publication.reason,
            resolverId: id
        )]
    }
}
