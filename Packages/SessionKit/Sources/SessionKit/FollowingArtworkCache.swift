import Foundation

/// Each followed show's artwork link, kept in a small side file keyed by subscription id (D3, #773).
///
/// A side file, not a database column or a new field: Build 29's frozen reader decodes
/// `FeedSubscription` and `FeedEntry`, and its database must open unchanged. The catalog's
/// artwork wins over the feed's own channel image when both are known.
public struct FollowingArtworkCache: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "following-artwork.v1"
    public static let fileName = "following-artwork.json"

    public struct Artwork: Codable, Equatable, Sendable {
        public var catalogURL: String?
        public var feedURL: String?

        public init(catalogURL: String? = nil, feedURL: String? = nil) {
            self.catalogURL = catalogURL
            self.feedURL = feedURL
        }

        enum CodingKeys: String, CodingKey {
            case catalogURL = "catalog_url"
            case feedURL = "feed_url"
        }
    }

    public private(set) var bySubscription: [String: Artwork]

    public init(bySubscription: [String: Artwork] = [:]) {
        self.bySubscription = bySubscription
    }

    /// The link to show for a subscription: the catalog's, else the feed's, else nil.
    public func artworkURL(for subscriptionID: String) -> URL? {
        guard let artwork = bySubscription[subscriptionID] else { return nil }
        return [artwork.catalogURL, artwork.feedURL].compactMap { $0.flatMap(Self.httpsURL) }.first
    }

    /// Records what a follow or refresh learned. A nil value keeps what was known before, so a
    /// refresh that doesn't repeat the image doesn't erase it.
    public mutating func record(catalogURL: String? = nil, feedURL: String? = nil, for subscriptionID: String) {
        var artwork = bySubscription[subscriptionID] ?? Artwork()
        if let catalogURL = catalogURL.flatMap(Self.httpsURL) { artwork.catalogURL = catalogURL.absoluteString }
        if let feedURL = feedURL.flatMap(Self.httpsURL) { artwork.feedURL = feedURL.absoluteString }
        guard artwork.catalogURL != nil || artwork.feedURL != nil else { return }
        bySubscription[subscriptionID] = artwork
    }

    /// Unfollowing drops the show's artwork.
    public mutating func remove(subscriptionID: String) {
        bySubscription[subscriptionID] = nil
    }

    /// Drops artwork for every subscription not in `subscriptionIDs`, such as ones unfollowed elsewhere.
    public mutating func keepOnly(_ subscriptionIDs: Set<String>) {
        bySubscription = bySubscription.filter { subscriptionIDs.contains($0.key) }
    }

    private static func httpsURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty else { return nil }
        return url
    }

    // MARK: File

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bySubscription = "subscriptions"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bySubscription = try container.decodeIfPresent([String: Artwork].self, forKey: .bySubscription) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(bySubscription, forKey: .bySubscription)
    }

    /// A missing or unreadable file means no artwork is known yet.
    public static func load(from url: URL) -> FollowingArtworkCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(FollowingArtworkCache.self, from: data) else { return FollowingArtworkCache() }
        return cache
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
