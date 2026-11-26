import Foundation
import SessionKit

/// What an article's own feed says about it (#4640), kept per launch by `FollowedSourceCoordinator`.
public enum ArticleFeedListing: Equatable, Sendable {
    /// A feed lists this page; the item is the one to read the enclosure from.
    case listed(ParsedFeedItem)
    /// Every feed the page links was read, and none lists this page.
    case notListed
    /// The address is itself a feed, or a Substack address that Substack's own lookup covers.
    case notAnArticlePage
}

/// What the article feed route found for one page (#4640).
public enum ArticleFeedAudioOutcome: Equatable, Sendable {
    case found(audioURL: String, durationMs: Int?, lengthBytes: Int?)
    /// Settled for the launch. `reason` is a short Diagnostics token.
    case none(reason: String)
    /// Worth trying again on the next open: the page could not be reached.
    case failed(String)
}

/// The pure rules of the article feed route (#4640): which feed item is this page's, and whether its enclosure may be
/// offered as the article's audio. No domain appears here: the route is the same for every publisher.
public enum ArticleFeedAudioRules {
    /// Tracking parameters dropped from a page address before matching.
    static let droppedQueryKeys: Set<String> = ["fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src"]

    /// A page address as the matcher compares it: scheme and host lower-cased, `http` and `https` alike, no leading
    /// `www.`, no fragment, no trailing slash, and no tracking parameters. `itemURLKey`, which Follow uses, is separate.
    public static func pageKey(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let items: [URLQueryItem] = components.queryItems ?? []
        let query = items
            .filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !droppedQueryKeys.contains(name)
            }
            .map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }
            .joined(separator: "&")
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(host)\(port)\(path)" + (query.isEmpty ? "" : "?\(query)")
    }

    /// The item among `items` that is the page at `pageKeys`, preferring one with an enclosure.
    public static func matchingItem(in items: [ParsedFeedItem], pageKeys: Set<String>) -> ParsedFeedItem? {
        let matches = items.filter { item in pageKey(item.url).map(pageKeys.contains) ?? false }
        return matches.first { $0.enclosureURL != nil } ?? matches.first
    }

    /// Whether the listed item's enclosure may play as the article's audio. Checks run in the Design's order, and the
    /// first that fails names the reason.
    public static func evaluate(listing: ArticleFeedListing, pageURL: URL, bodyWordCount: Int?) -> ArticleFeedAudioOutcome {
        let item: ParsedFeedItem
        switch listing {
        case .notAnArticlePage: return .none(reason: "not_an_article_page")
        case .notListed: return .none(reason: "not_listed")
        case .listed(let listed): item = listed
        }
        guard let raw = item.enclosureURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .none(reason: "not_listed")
        }
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.port == nil else {
            return .none(reason: "insecure")
        }
        let type = item.enclosureType?.lowercased() ?? ""
        let fileExtension = (components.path as NSString).pathExtension.lowercased()
        if fileExtension == "m3u8" || type.contains("mpegurl") { return .none(reason: "hls_unsupported") }
        guard type.hasPrefix("audio/") || ["mp3", "m4a", "aac", "wav"].contains(fileExtension) else {
            return .none(reason: "not_audio")
        }
        if PublisherAudioAdmission.isSigned(components) { return .none(reason: "signed_url") }
        if pageKey(raw) == pageKey(pageURL.absoluteString) { return .none(reason: "same_as_page") }
        if let words = bodyWordCount, words < PublisherAudioDetector.minimumBodyWords { return .none(reason: "short_body") }
        let durationMs = item.durationMs.flatMap { $0 > 0 ? $0 : nil }
        let lengthBytes = item.enclosureLengthBytes.flatMap { $0 > 0 ? $0 : nil }
        guard durationMs != nil || lengthBytes != nil else { return .none(reason: "no_size") }
        switch PublisherAudioNarrationFit.verdict(durationMs: durationMs, lengthBytes: lengthBytes, wordCount: bodyWordCount) {
        case .tooLong?: return .none(reason: "too_long")
        case .tooShort?: return .none(reason: "too_short")
        case .fits?, nil: return .found(audioURL: raw, durationMs: durationMs, lengthBytes: lengthBytes)
        }
    }
}
