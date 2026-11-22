import Foundation

/// The shows a listener's own AI suggested following, waiting for the listener to look at them (#4683, Design
/// section 2h). A link list's `"follow": true` entries are never followed silently: they land here, and Following
/// shows one "Suggested by your AI" row that opens the existing follow preview.
///
/// Kept in `UserDefaults` under `defaultsKey` as JSON, so no database changes and the previous build opens the same
/// database. Records are ordered by `addedAt` (oldest first), have no two feed links that are the same by
/// `FeedURLKey`, and number at most `maxSuggestions`; past that the oldest go first.
///
/// No call site yet: PR 3 of #4683 stores the follow entries of an arrival here, and the row reads it.
public final class AIFollowSuggestions: @unchecked Sendable {
    public static let defaultsKey = "aiFollowSuggestionsV1"
    /// The most suggestions kept; a daily brief carries at most `LinkListFile.maxFollows`.
    public static let maxSuggestions = 20

    public struct Suggestion: Codable, Equatable, Sendable {
        /// The feed link as the list wrote it.
        public var url: String
        /// Identifies the list it came from (the arrival's key), so Undo can take that list's suggestions back.
        public var listKey: String
        /// The list's title, nil for an untitled list.
        public var listTitle: String?
        public var addedAt: Date

        public init(url: String, listKey: String, listTitle: String?, addedAt: Date) {
            self.url = url
            self.listKey = listKey
            self.listTitle = listTitle
            self.addedAt = addedAt
        }
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every pending suggestion, oldest first.
    public func all() -> [Suggestion] {
        lock.withLock { read() }
    }

    /// The suggestions whose feed is not in `followed` (a set of `FeedURLKey`s of current subscriptions). Following's
    /// inputs use this, so a show followed some other way never lingers in the row.
    public func pending(excluding followed: Set<String>) -> [Suggestion] {
        all().filter { !Self.isFollowed($0.url, in: followed) }
    }

    /// The title of the newest list among `suggestions`: the one with the latest `addedAt` (the last stored on a tie).
    /// Nil when there are none or that list had no title.
    public static func newestListTitle(in suggestions: [Suggestion]) -> String? {
        guard let newest = suggestions.enumerated().max(by: { ($0.element.addedAt, $0.offset) < ($1.element.addedAt, $1.offset) })
        else { return nil }
        return newest.element.listTitle
    }

    /// Adds a list's shows. A link already waiting (same `FeedURLKey`) or already followed (`followed` holds its key)
    /// is skipped, and a link that is not a feed link at all is skipped. Returns how many were newly added.
    @discardableResult
    public func merge(
        urls: [String],
        listKey: String,
        listTitle: String?,
        addedAt: Date,
        followed: Set<String> = []
    ) -> Int {
        lock.withLock {
            var records = read()
            var known = Set(records.compactMap { FeedURLKey.make($0.url) })
            var added = 0
            for url in urls {
                guard let key = FeedURLKey.make(url), !followed.contains(key), known.insert(key).inserted else { continue }
                records.append(Suggestion(url: url, listKey: listKey, listTitle: listTitle, addedAt: addedAt))
                added += 1
            }
            guard added > 0 else { return 0 }
            write(Self.trimmed(records))
            return added
        }
    }

    /// Removes the suggestions for these feed links, matched by `FeedURLKey` (the shows the preview followed, and the
    /// ones it marked unusable).
    public func remove(urls: [String]) {
        let keys = Set(urls.compactMap(FeedURLKey.make))
        guard !keys.isEmpty else { return }
        lock.withLock {
            let records = read()
            let kept = records.filter { FeedURLKey.make($0.url).map { !keys.contains($0) } ?? true }
            if kept.count != records.count { write(kept) }
        }
    }

    /// Removes every suggestion that came from one list, for Undo of that arrival.
    public func remove(listKey: String) {
        lock.withLock {
            let records = read()
            let kept = records.filter { $0.listKey != listKey }
            if kept.count != records.count { write(kept) }
        }
    }

    /// Drops the suggestions whose feed is in `followed`, so a show followed another way leaves the store.
    public func dropFollowed(_ followed: Set<String>) {
        guard !followed.isEmpty else { return }
        lock.withLock {
            let records = read()
            let kept = records.filter { !Self.isFollowed($0.url, in: followed) }
            if kept.count != records.count { write(kept) }
        }
    }

    /// Removes all of them (the row's Dismiss) and returns what was there, to hand to `restore` for its Undo.
    @discardableResult
    public func dismissAll() -> [Suggestion] {
        lock.withLock {
            let previous = read()
            write([])
            return previous
        }
    }

    /// Puts back the array `dismissAll` returned, whole. A suggestion that arrived after the dismiss is kept beside
    /// them (the same cap and order apply), so Undo never throws away a list that landed in between.
    public func restore(_ previous: [Suggestion]) {
        lock.withLock {
            let previousKeys = Set(previous.compactMap { FeedURLKey.make($0.url) })
            let newer = read().filter { FeedURLKey.make($0.url).map { !previousKeys.contains($0) } ?? true }
            write(Self.trimmed(previous + newer))
        }
    }

    // MARK: Storage

    private static func isFollowed(_ url: String, in followed: Set<String>) -> Bool {
        FeedURLKey.make(url).map(followed.contains) ?? false
    }

    /// Oldest first (a stable sort, so an equal `addedAt` keeps its stored order), at most `maxSuggestions`, the
    /// oldest dropped first.
    private static func trimmed(_ records: [Suggestion]) -> [Suggestion] {
        let ordered = records.enumerated()
            .sorted { ($0.element.addedAt, $0.offset) < ($1.element.addedAt, $1.offset) }
            .map(\.element)
        return Array(ordered.suffix(maxSuggestions))
    }

    private func read() -> [Suggestion] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Data this build can't read is treated as empty, and is overwritten by the next write.
        return (try? decoder.decode([Suggestion].self, from: data)) ?? []
    }

    private func write(_ records: [Suggestion]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
