import Foundation

/// The picture shown for each Library item (#3864), kept in a small side file, `item-artwork.json`,
/// beside `following-artwork.json`.
///
/// A side file, not a database column: an earlier build opens the database unchanged, and a build
/// that re-saves an item can't drop a field it doesn't know. The same reason `FollowingArtworkCache`
/// gives. Packets carry no images and never will.
///
/// Precedence, the one documented rule (`artworkURL(for:following:)`):
/// 1. the item's own image: one recorded for the item, else its feed entry's own image;
/// 2. the source's image: one recorded for the item, else the show image of the followed feed that lists it;
/// 3. nil, which draws today's icon.
///
/// Only https links are kept.
public struct ItemArtworkStore: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "item-artwork.v1"
    public static let fileName = "item-artwork.json"

    /// What is recorded for one Library item.
    public struct ItemArt: Codable, Equatable, Sendable {
        public var itemImageURL: String?
        public var sourceImageURL: String?

        public init(itemImageURL: String? = nil, sourceImageURL: String? = nil) {
            self.itemImageURL = itemImageURL
            self.sourceImageURL = sourceImageURL
        }

        enum CodingKeys: String, CodingKey {
            case itemImageURL = "item_image_url"
            case sourceImageURL = "source_image_url"
        }
    }

    /// What a followed feed's entry looked like at its last refresh: which show it belongs to and its own image.
    public struct EntryArt: Codable, Equatable, Sendable {
        public var subscriptionId: String
        public var imageURL: String?

        public init(subscriptionId: String, imageURL: String? = nil) {
            self.subscriptionId = subscriptionId
            self.imageURL = imageURL
        }

        enum CodingKeys: String, CodingKey {
            case subscriptionId = "subscription_id"
            case imageURL = "image_url"
        }
    }

    /// One parsed feed entry, as `recordEntries` takes it.
    public struct EntryImage: Equatable, Sendable {
        public var guid: String?
        public var url: String
        public var imageURL: String?

        public init(guid: String?, url: String, imageURL: String?) {
            self.guid = guid
            self.url = url
            self.imageURL = imageURL
        }
    }

    /// What matching an item to its feed entry reads: the id, the feed GUID and the page address. An `Item`
    /// without its text has them, and so does the Library row, which has no GUID and finds its picture by id.
    public struct ItemKey: Equatable, Sendable {
        public var id: String
        public var episodeGUID: String?
        public var sourceURL: String?

        public init(id: String, episodeGUID: String? = nil, sourceURL: String? = nil) {
            self.id = id
            self.episodeGUID = episodeGUID
            self.sourceURL = sourceURL
        }

        public init(_ item: Item) {
            self.init(id: item.id, episodeGUID: item.episodeGUID, sourceURL: item.sourceURL)
        }
    }

    /// By Library item id.
    public private(set) var items: [String: ItemArt]
    /// By `guid:<episode GUID>` or `url:<normalised page address>`, the two ways an item finds its entry.
    public private(set) var entries: [String: EntryArt]

    public init(items: [String: ItemArt] = [:], entries: [String: EntryArt] = [:]) {
        self.items = items
        self.entries = entries
    }

    // MARK: Reading

    /// The link to draw for an item, or nil for today's icon.
    public func artworkURL(for item: ItemKey, following: FollowingArtworkCache) -> URL? {
        let recorded = items[item.id]
        let entry = entryArt(for: item)
        let own = [recorded?.itemImageURL, entry?.imageURL]
        let source = [recorded?.sourceImageURL, entry.flatMap { following.artworkURL(for: $0.subscriptionId)?.absoluteString }]
        return (own + source).lazy.compactMap { $0.flatMap(Self.httpsURL) }.first
    }

    // MARK: Recording

    /// A follow or refresh parsed these entries of `subscriptionID`. An entry with no image is still recorded,
    /// so its item can take the show's image. A repeat refresh that no longer lists an entry keeps what was known.
    public mutating func recordEntries(_ parsed: [EntryImage], subscriptionID: String) {
        for entry in parsed {
            let art = EntryArt(subscriptionId: subscriptionID, imageURL: entry.imageURL.flatMap(Self.httpsURL)?.absoluteString)
            for key in Self.keys(guid: entry.guid, url: entry.url) {
                // A refresh that stops repeating the image must not erase it.
                var next = art
                if next.imageURL == nil, entries[key]?.subscriptionId == subscriptionID { next.imageURL = entries[key]?.imageURL }
                entries[key] = next
            }
        }
    }

    /// Records links known for one item when it is added, such as an article's own image. A nil value keeps what was known.
    public mutating func recordItem(id: String, itemImageURL: String? = nil, sourceImageURL: String? = nil) {
        var art = items[id] ?? ItemArt()
        if let url = itemImageURL.flatMap(Self.httpsURL) { art.itemImageURL = url.absoluteString }
        if let url = sourceImageURL.flatMap(Self.httpsURL) { art.sourceImageURL = url.absoluteString }
        guard art.itemImageURL != nil || art.sourceImageURL != nil else { return }
        items[id] = art
    }

    /// Unfollowing drops the show's entries; items that already took their image keep it (see `reconcile`).
    public mutating func removeEntries(subscriptionID: String) {
        entries = entries.filter { $0.value.subscriptionId != subscriptionID }
    }

    /// Keeps only shows still followed.
    public mutating func keepEntries(forSubscriptions subscriptionIDs: Set<String>) {
        entries = entries.filter { subscriptionIDs.contains($0.value.subscriptionId) }
    }

    /// The Library changed, or a feed refreshed. Items gone from the Library lose their record, and each
    /// remaining item takes what its followed feed knows now (its entry's own image and its show's image), so
    /// the image survives the entry aging out of the feed or the show being unfollowed. Items from before
    /// this build get their image this way. An item already recorded keeps its own recorded links first.
    /// Nothing is fetched and no item changes. Run it off the main thread.
    public mutating func reconcile(items library: [ItemKey], following: FollowingArtworkCache) {
        let ids = Set(library.map(\.id))
        items = items.filter { ids.contains($0.key) }
        for item in library {
            guard let entry = entryArt(for: item) else { continue }
            recordItem(
                id: item.id,
                itemImageURL: entry.imageURL,
                sourceImageURL: following.artworkURL(for: entry.subscriptionId)?.absoluteString
            )
        }
    }

    // MARK: Matching

    private func entryArt(for item: ItemKey) -> EntryArt? {
        for key in Self.keys(guid: item.episodeGUID, url: item.sourceURL) {
            if let entry = entries[key] { return entry }
        }
        return nil
    }

    /// The GUID first: it names the episode whatever address its audio or page has. A page address matches after
    /// case in the scheme and host, a trailing slash, a default port and a fragment are ignored; the query stays.
    static func keys(guid: String?, url: String?) -> [String] {
        var keys: [String] = []
        if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty { keys.append("guid:" + guid) }
        if let url = FollowedSourceMatching.normalizedFollowSourceURL(url) { keys.append("url:" + url) }
        return keys
    }

    private static func httpsURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty else { return nil }
        return url
    }

    // MARK: File

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
        case entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([String: ItemArt].self, forKey: .items) ?? [:]
        entries = try container.decodeIfPresent([String: EntryArt].self, forKey: .entries) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(items, forKey: .items)
        try container.encode(entries, forKey: .entries)
    }

    /// A missing or unreadable file means no artwork is known yet.
    public static func load(from url: URL) -> ItemArtworkStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(ItemArtworkStore.self, from: data) else { return ItemArtworkStore() }
        return store
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The item artwork side file with its file: changes are written straight away, and only when they change
/// something. A nil file keeps the artwork in memory.
public struct ItemArtworkFile: Sendable {
    public let file: URL?
    public private(set) var store: ItemArtworkStore

    public init(file: URL?) {
        self.file = file
        store = file.map(ItemArtworkStore.load(from:)) ?? ItemArtworkStore()
    }

    public mutating func update(_ change: (inout ItemArtworkStore) -> Void) {
        let before = store
        change(&store)
        guard store != before, let file else { return }
        try? store.save(to: file)
    }
}

/// A repository that can list every live item's matching keys without reading the Library's text. The store
/// answers from the cut of each item it already keeps for the Library list, so a reconcile does not decode every
/// document. Another repository is read the full way.
public protocol ItemArtworkKeyListing {
    func listItemArtworkKeys() throws -> [ItemArtworkStore.ItemKey]
}
