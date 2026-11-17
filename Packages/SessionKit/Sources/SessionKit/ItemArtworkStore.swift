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
/// What was recorded for an item directly (`recordItem`) and what `reconcile` copied from its feed are kept in
/// separate fields, so a copy from the feed can never replace a recorded link: the order is a read order, not a
/// write race. A feed GUID names an episode only within its show, so a GUID matches an entry only when the item
/// names the same show; an item that doesn't is matched by its page address alone.
///
/// Only https links are kept.
public struct ItemArtworkStore: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "item-artwork.v1"
    public static let fileName = "item-artwork.json"

    /// What is recorded for one Library item.
    public struct ItemArt: Codable, Equatable, Sendable {
        /// Recorded for the item itself, such as an article's own image. Only `recordItem` writes these.
        public var itemImageURL: String?
        public var sourceImageURL: String?
        /// Copied from the item's followed feed by `reconcile`, and only by it: the entry's own image and the show's.
        public var feedItemImageURL: String?
        public var feedSourceImageURL: String?

        public init(itemImageURL: String? = nil, sourceImageURL: String? = nil,
                    feedItemImageURL: String? = nil, feedSourceImageURL: String? = nil) {
            self.itemImageURL = itemImageURL
            self.sourceImageURL = sourceImageURL
            self.feedItemImageURL = feedItemImageURL
            self.feedSourceImageURL = feedSourceImageURL
        }

        /// The links in read order: recorded own, feed own, recorded source, feed source.
        var orderedLinks: [String?] { [itemImageURL, feedItemImageURL, sourceImageURL, feedSourceImageURL] }

        enum CodingKeys: String, CodingKey {
            case itemImageURL = "item_image_url"
            case sourceImageURL = "source_image_url"
            case feedItemImageURL = "feed_item_image_url"
            case feedSourceImageURL = "feed_source_image_url"
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
        /// The show the item names. A GUID matches only within one show, so an item without one matches by address only.
        public var showTitle: String?

        public init(id: String, episodeGUID: String? = nil, sourceURL: String? = nil, showTitle: String? = nil) {
            self.id = id
            self.episodeGUID = episodeGUID
            self.sourceURL = sourceURL
            self.showTitle = showTitle
        }

        public init(_ item: Item) {
            self.init(id: item.id, episodeGUID: item.episodeGUID, sourceURL: item.sourceURL, showTitle: item.showTitle)
        }
    }

    /// By Library item id.
    public private(set) var items: [String: ItemArt]
    /// By `guid:<show>\u{1F}<episode GUID>` or `url:<normalised page address>`, the two ways an item finds its entry.
    /// The show in a GUID key is its folded title, so two shows that reuse a GUID never share an entry.
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
        let own = [recorded?.itemImageURL, entry?.imageURL, recorded?.feedItemImageURL]
        let source = [recorded?.sourceImageURL, entry.flatMap { following.artworkURL(for: $0.subscriptionId)?.absoluteString },
                      recorded?.feedSourceImageURL]
        return (own + source).lazy.compactMap { $0.flatMap(Self.httpsURL) }.first
    }

    /// The link recorded for an item id: its own image, else its source's. A Library row reads this at every draw, so it
    /// does only a dictionary lookup; `reconcile` is what recorded what its feed knows. Precedence is `artworkURL`'s.
    public func recordedArtworkURL(forItem id: String) -> URL? {
        guard let art = items[id] else { return nil }
        return art.orderedLinks.lazy.compactMap { $0.flatMap(Self.httpsURL) }.first
    }

    // MARK: Recording

    /// A follow or refresh parsed these entries of `subscriptionID`. An entry with no image is still recorded,
    /// so its item can take the show's image. A repeat refresh that no longer lists an entry keeps what was known.
    /// `showTitle` is the feed's own title: an entry's GUID is only recorded under its show, and none is recorded for
    /// a feed with no title (its entries are still found by address).
    public mutating func recordEntries(_ parsed: [EntryImage], subscriptionID: String, showTitle: String? = nil) {
        for entry in parsed {
            let art = EntryArt(subscriptionId: subscriptionID, imageURL: entry.imageURL.flatMap(Self.httpsURL)?.absoluteString)
            for key in Self.keys(guid: entry.guid, url: entry.url, showTitle: showTitle) {
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

    /// The Library changed, or a feed refreshed. `items` is every item still stored, trashed ones included: a record
    /// is dropped only when its item is gone for good, so restoring an item from the Trash brings its picture back.
    /// Each item takes what its followed feed knows now (its entry's own image and its show's image) into its
    /// `feed…` fields, so the image survives the entry aging out of the feed or the show being unfollowed. Items
    /// from before this build get their image this way. Links recorded for an item directly are never touched
    /// and are read first. Nothing is fetched and no item changes. Run it off the main thread.
    public mutating func reconcile(items library: [ItemKey], following: FollowingArtworkCache) {
        let ids = Set(library.map(\.id))
        items = items.filter { ids.contains($0.key) }
        for item in library {
            guard let entry = entryArt(for: item) else { continue }
            var art = items[item.id] ?? ItemArt()
            if let url = entry.imageURL.flatMap(Self.httpsURL) { art.feedItemImageURL = url.absoluteString }
            if let url = following.artworkURL(for: entry.subscriptionId).flatMap({ Self.httpsURL($0.absoluteString) }) {
                art.feedSourceImageURL = url.absoluteString
            }
            guard art.orderedLinks.contains(where: { $0 != nil }) else { continue }
            items[item.id] = art
        }
    }

    // MARK: Matching

    private func entryArt(for item: ItemKey) -> EntryArt? {
        for key in Self.keys(guid: item.episodeGUID, url: item.sourceURL, showTitle: item.showTitle) {
            if let entry = entries[key] { return entry }
        }
        return nil
    }

    /// The GUID first: it names the episode whatever address its audio or page has, but only within its show, so it
    /// is keyed with the show's folded title and left out when the show is unknown. A page address matches after
    /// case in the scheme and host, a trailing slash, a default port and a fragment are ignored; the query stays.
    static func keys(guid: String?, url: String?, showTitle: String?) -> [String] {
        var keys: [String] = []
        if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty,
           let show = foldedShowTitle(showTitle) {
            keys.append("guid:" + show + "\u{1F}" + guid)
        }
        if let url = FollowedSourceMatching.normalizedFollowSourceURL(url) { keys.append("url:" + url) }
        return keys
    }

    /// A show title with entities decoded, tags and extra spaces dropped, and case and accents folded; nil when nothing
    /// is left. Import paths clean a feed's title differently (Following drops tags and decodes `&amp;`; a direct RSS
    /// add keeps CDATA text as written), so both sides get this cleanup. The same cleanup as
    /// `PortableArticleAnchorResolver.foldedShowTitle` (SessionKitSharing, which this module can't import).
    static func foldedShowTitle(_ value: String?) -> String? {
        let cleaned = value?
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard let cleaned, !cleaned.isEmpty else { return nil }
        return cleaned
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
///
/// `init(file:)` reads the file there and then, so call it off the main thread. `init(file:deferringRead:)` with `true`
/// reads nothing until the first `loadIfNeeded()` or `update`, which is how an actor that is built on the main
/// thread keeps the read (a synchronous decode that grows with the followed feeds) inside its own isolation.
/// `store` is empty until the file has been read.
public struct ItemArtworkFile: Sendable {
    public let file: URL?
    public private(set) var store: ItemArtworkStore
    private var isLoaded: Bool

    public init(file: URL?, deferringRead: Bool = false) {
        self.file = file
        if deferringRead, file != nil {
            store = ItemArtworkStore()
            isLoaded = false
        } else {
            store = file.map(ItemArtworkStore.load(from:)) ?? ItemArtworkStore()
            isLoaded = true
        }
    }

    /// Reads the file once, if the read was deferred.
    public mutating func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        if let file { store = ItemArtworkStore.load(from: file) }
    }

    public mutating func update(_ change: (inout ItemArtworkStore) -> Void) {
        loadIfNeeded()
        let before = store
        change(&store)
        guard store != before, let file else { return }
        try? store.save(to: file)
    }
}

/// A repository that can list every stored item's matching keys, trashed ones included, without reading the Library's text. The store
/// answers from the cut of each item it already keeps for the Library list, so a reconcile does not decode every
/// document. Another repository is read the full way.
public protocol ItemArtworkKeyListing {
    func listItemArtworkKeys() throws -> [ItemArtworkStore.ItemKey]
}
