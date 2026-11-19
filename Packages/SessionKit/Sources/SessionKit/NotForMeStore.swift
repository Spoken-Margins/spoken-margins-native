import Foundation

/// A synchronous read of what the listener said "Not for me" to, for code that can't await the store: the drawer
/// draws from `current`, and the followed-source coordinator asks `isMarked` for each entry it is about to save
/// (#4285). `NotForMeStore` fills it after every write; until its first load the box is empty.
public final class NotForMeSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = NotForMeSnapshot.empty
    private var marked: [String: Set<String>] = [:]

    public init() {}

    public var current: NotForMeSnapshot {
        lock.withLock { snapshot }
    }

    /// Whether an episode of the feed `feedKey` (a `NotForMeStore.feedKey(for:)`) was marked, by the key the mark
    /// was taken with.
    public func isMarked(feedKey: String, entryKey: String) -> Bool {
        lock.withLock { marked[feedKey]?.contains(entryKey) ?? false }
    }

    /// The coordinator's `suppressedEntry` provider, backed by this box.
    public var suppressedEntry: @Sendable (_ feedKey: String, _ entryKey: String) -> Bool {
        { [self] feedKey, entryKey in isMarked(feedKey: feedKey, entryKey: entryKey) }
    }

    fileprivate func publish(snapshot: NotForMeSnapshot, marked: [String: Set<String>]) {
        lock.withLock {
            self.snapshot = snapshot
            self.marked = marked
        }
    }
}

/// What the listener marked "Not for me", kept on the phone in `Application Support/not-for-me.json` (#4285).
///
/// Two kinds of record. A hidden **source** leaves every pack, the Top list and the chips; it is matched by its
/// catalog entry id or by its normalized feed key. A marked **item** is one episode the listener will never see in
/// New again: the coordinator saves it as `.dismissed` even after the show is unfollowed and followed again, which
/// deletes the stored entries. The file is JSON, not SQLite, so the previous build still opens the database.
public actor NotForMeStore {
    public static let fileName = "not-for-me.json"
    public static let unreadableFileName = "not-for-me.unreadable.json"
    public static let currentVersion = 1
    /// A feed lists its newest 25 items, so a mark older than the newest 200 is on an episode no longer shown.
    public static let maximumMarksPerFeed = 200

    public struct HiddenSource: Codable, Equatable, Sendable {
        public var catalogEntryId: String?
        public var feedKey: String
        public var title: String
        public var artworkURL: String?
        public var hiddenAt: Date
    }

    public struct MarkedItem: Codable, Equatable, Sendable {
        public var feedKey: String
        public var entryKey: String
        public var title: String
        public var hiddenAt: Date
    }

    private struct FileContents: Codable {
        var version: Int
        var sources: [HiddenSource]
        var items: [MarkedItem]
    }

    public enum StoreError: Error, Equatable, Sendable {
        /// The feed address has no host, so there is nothing to match a hide or a mark by.
        case unusableFeedURL
        /// The item has no GUID, page address or audio address to recognise it by.
        case unidentifiableItem
        /// The file exists but can't be read yet, so a write would replace marks this store hasn't seen.
        case fileNotReadable
    }

    public nonisolated let box: NotForMeSnapshotBox
    private let fileURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var sources: [HiddenSource] = []
    private var items: [MarkedItem] = []
    private var loaded = false

    /// Reads nothing: `load()` does, and the app awaits it before its first followed-source refresh so a launch
    /// refresh can't revive a mark.
    public init(
        fileURL: URL,
        box: NotForMeSnapshotBox = NotForMeSnapshotBox(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.box = box
        self.fileManager = fileManager
        self.now = now
    }

    /// The key a hide or a mark is stored under for this feed address: the same normalization a follow matches by.
    public nonisolated static func feedKey(for feedURL: String) -> String? { FeedURLKey.make(feedURL) }

    /// The key a mark is taken with: the feed's GUID, else the post address, else the audio address.
    public nonisolated static func entryKey(guid: String?, canonicalURL: String?, audioURL: String?) -> String? {
        [guid, canonicalURL, audioURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Every key an episode might have been marked with, in the order `entryKey` prefers them. A mark taken
    /// before the feed carried a GUID has the page address, so all three are asked.
    public nonisolated static func entryKeys(guid: String?, canonicalURL: String?, audioURL: String?) -> [String] {
        var seen = Set<String>()
        return [guid, canonicalURL, audioURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Loading

    /// Reads the file once. A missing file is an empty store. A file that was read but can't be decoded, or that
    /// carries another version, is renamed to `not-for-me.unreadable.json` so nothing is lost, and the store starts
    /// empty. A file that can't be *read* (the phone is still locked, say) is left exactly where it is: the store
    /// reads as empty for now, tries again on the next call, and refuses every write until the read works, so a
    /// write can't replace marks it never saw.
    public func load() {
        guard !loaded else { return }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            loaded = true
            publish()
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            publish()
            return
        }
        loaded = true
        if let contents = try? Self.decoder.decode(FileContents.self, from: data), contents.version == Self.currentVersion {
            sources = contents.sources
            items = contents.items
        } else {
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent(Self.unreadableFileName)
            if (try? fileManager.moveItem(at: fileURL, to: aside)) == nil {
                // The old aside copy is replaced only when the new one can be put there.
                try? fileManager.removeItem(at: aside)
                try? fileManager.moveItem(at: fileURL, to: aside)
            }
        }
        publish()
    }

    // MARK: Reading

    public func hiddenSources() -> [HiddenSource] {
        loadIfNeeded()
        return sources.sorted { ($0.hiddenAt, $1.feedKey) > ($1.hiddenAt, $0.feedKey) }
    }

    public func markedItems(feedKey: String) -> [MarkedItem] {
        loadIfNeeded()
        return items.filter { $0.feedKey == feedKey }
    }

    public func snapshot() -> NotForMeSnapshot {
        loadIfNeeded()
        return Self.snapshot(sources: sources, items: items)
    }

    // MARK: Hiding a source

    /// Hides a show. Hiding it again updates its record instead of adding a second one.
    public func hideSource(catalogEntryId: String?, feedURL: String, title: String, artworkURL: String?) throws {
        loadIfNeeded()
        guard let key = Self.feedKey(for: feedURL) else { throw StoreError.unusableFeedURL }
        var next = sources.filter { $0.feedKey != key }
        next.append(HiddenSource(catalogEntryId: catalogEntryId, feedKey: key, title: title, artworkURL: artworkURL, hiddenAt: now()))
        try commit(sources: next, items: items)
    }

    /// "Show again": takes the hide off. Marks on its episodes stay.
    public func showAgain(feedURL: String) throws {
        loadIfNeeded()
        guard let key = Self.feedKey(for: feedURL) else { return }
        guard sources.contains(where: { $0.feedKey == key }) else { return }
        try commit(sources: sources.filter { $0.feedKey != key }, items: items)
    }

    /// A followed source is never hidden: drops every hide that matches a live subscription, by feed key or by
    /// catalog entry id. Returns what it dropped.
    @discardableResult
    public func removeHides(followedFeedKeys: Set<String>, followedEntryIds: Set<String>) throws -> [HiddenSource] {
        loadIfNeeded()
        let dropped = sources.filter { source in
            followedFeedKeys.contains(source.feedKey) || source.catalogEntryId.map(followedEntryIds.contains) == true
        }
        guard !dropped.isEmpty else { return [] }
        let droppedKeys = Set(dropped.map(\.feedKey))
        try commit(sources: sources.filter { !droppedKeys.contains($0.feedKey) }, items: items)
        return dropped
    }

    // MARK: Marking an episode

    /// Marks an episode. Marking it again moves it to the newest. The oldest marks of a feed past 200 are dropped.
    public func markItem(feedURL: String, guid: String?, canonicalURL: String?, audioURL: String?, title: String) throws {
        loadIfNeeded()
        guard let feedKey = Self.feedKey(for: feedURL) else { throw StoreError.unusableFeedURL }
        guard let entryKey = Self.entryKey(guid: guid, canonicalURL: canonicalURL, audioURL: audioURL) else {
            throw StoreError.unidentifiableItem
        }
        var next = items.filter { !($0.feedKey == feedKey && $0.entryKey == entryKey) }
        next.append(MarkedItem(feedKey: feedKey, entryKey: entryKey, title: title, hiddenAt: now()))
        try commit(sources: sources, items: Self.capped(next))
    }

    /// Undo: takes the mark off. Any key the episode might carry matches, like the coordinator's check.
    public func unmarkItem(feedURL: String, guid: String?, canonicalURL: String?, audioURL: String?) throws {
        loadIfNeeded()
        guard let feedKey = Self.feedKey(for: feedURL) else { return }
        let keys = Set(Self.entryKeys(guid: guid, canonicalURL: canonicalURL, audioURL: audioURL))
        let next = items.filter { !($0.feedKey == feedKey && keys.contains($0.entryKey)) }
        guard next.count != items.count else { return }
        try commit(sources: sources, items: next)
    }

    // MARK: Writing

    private static func capped(_ items: [MarkedItem]) -> [MarkedItem] {
        var keptPerFeed: [String: Int] = [:]
        // Walk newest first (later in the array is newer on a tie), keep 200 per feed, restore the order.
        let ordered = items.enumerated().sorted { lhs, rhs in
            if lhs.element.hiddenAt != rhs.element.hiddenAt { return lhs.element.hiddenAt > rhs.element.hiddenAt }
            return lhs.offset > rhs.offset
        }
        var keep = Set<Int>()
        for (offset, item) in ordered {
            let count = keptPerFeed[item.feedKey, default: 0]
            if count < maximumMarksPerFeed {
                keptPerFeed[item.feedKey] = count + 1
                keep.insert(offset)
            }
        }
        return items.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }

    /// Writes the file, then swaps the state in and publishes. A write that fails changes nothing.
    private func commit(sources newSources: [HiddenSource], items newItems: [MarkedItem]) throws {
        loadIfNeeded()
        guard loaded else { throw StoreError.fileNotReadable }
        let contents = FileContents(version: Self.currentVersion, sources: newSources, items: newItems)
        let data = try Self.encoder.encode(contents)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        sources = newSources
        items = newItems
        publish()
    }

    private func loadIfNeeded() {
        if !loaded { load() }
    }

    private func publish() {
        var marked: [String: Set<String>] = [:]
        for item in items { marked[item.feedKey, default: []].insert(item.entryKey) }
        box.publish(snapshot: Self.snapshot(sources: sources, items: items), marked: marked)
    }

    private static func snapshot(sources: [HiddenSource], items: [MarkedItem]) -> NotForMeSnapshot {
        var marks: [String: Int] = [:]
        for item in items { marks[item.feedKey, default: 0] += 1 }
        return NotForMeSnapshot(
            hiddenEntryIds: Set(sources.compactMap(\.catalogEntryId)),
            hiddenFeedKeys: Set(sources.map(\.feedKey)),
            marksByFeedKey: marks
        )
    }

    /// Dates are written with fractional seconds, so a mark made in the same second as another keeps its order
    /// after a reload; a file with whole seconds still reads.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalFormatter.date(from: raw) ?? wholeSecondFormatter.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(raw)"))
        }
        return decoder
    }

    private static var fractionalFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var wholeSecondFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
