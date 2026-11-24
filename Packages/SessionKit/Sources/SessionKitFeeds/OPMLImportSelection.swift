import Foundation
import SessionKit

/// #4920: the one order the import preview and its result list shows in: A to Z by the name on the row, with
/// rows that have no name of their own (their title is their feed address) after every named row. Following
/// still runs in source order (`OPMLImportRunner`); this order is only what the listener reads.
///
/// The comparison folds case and accents and orders numbers by value ("Show 2" before "Show 10"), without
/// locale collation, so it is the same on the phone and in the Linux tests. It is a total order:
/// named before nameless, folded titles (numeric), then the plain titles ("Apple" before "apple"),
/// then the folded hosts, then input position (so the sort is stable).
public enum OPMLImportOrder {
    public static func sorted<T>(_ items: [T], title: (T) -> String, feedURL: (T) -> String?) -> [T] {
        let keys = items.enumerated().map { index, item -> SortKey in
            let rawTitle = title(item)
            let url = feedURL(item)
            return SortKey(
                index: index,
                nameless: isNameless(title: rawTitle, feedURL: url),
                folded: fold(rawTitle),
                plain: rawTitle.precomposedStringWithCanonicalMapping,
                host: fold(url.flatMap { URLComponents(string: $0)?.host } ?? "")
            )
        }
        let ordered = keys.sorted { a, b in
            if a.nameless != b.nameless { return !a.nameless }
            switch a.folded.compare(b.folded, options: [.numeric]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: break
            }
            if a.plain != b.plain { return a.plain < b.plain }
            if a.host != b.host { return a.host < b.host }
            return a.index < b.index
        }
        return ordered.map { items[$0.index] }
    }

    private struct SortKey {
        let index: Int
        let nameless: Bool
        let folded: String
        let plain: String
        let host: String
    }

    /// True when the row's title is its own feed address: both parsers fall back to the feed link when a row has no name.
    /// #4858: also true for the readable fallback title once it lands.
    public static func isNameless(title: String, feedURL: String?) -> Bool {
        guard let feedURL, let titleKey = FeedURLKey.make(title) else { return false }
        return titleKey == FeedURLKey.make(feedURL)
    }

    /// Case and accents folded, in composed form. Deterministic on Apple platforms and Linux.
    public static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// #4920: the listener's ticks on an import preview, with its sorted rows and its search. The preview is the planner's
/// read of the file; this is what the listener changes on it. Select All and Deselect All act on the New rows shown
/// (all of New with no search, the matches during one); ticks hidden by a search stay ticked, and "Follow N" counts
/// every ticked row. It takes no transport and no follow closure, so it cannot make a request or touch playback.
public struct OPMLImportSelection: Equatable, Sendable {
    /// A row of the Already followed or Repeated section. `id` is its index in the preview's array, assigned before
    /// sorting, so it stays stable through sorting and filtering.
    public struct FeedRow: Identifiable, Equatable, Sendable {
        public let id: Int
        public let feed: OPMLFeed
    }

    /// The rows one search shows. With no query, every row.
    public struct Matches: Equatable, Sendable {
        public let query: String?
        public let new: [SourceCandidate]
        public let alreadyFollowed: [FeedRow]
        public let repeated: [FeedRow]
        public var isSearching: Bool { query != nil }
    }

    /// The search field shows only above this many New rows.
    public static let searchThreshold = 10

    public let newRows: [SourceCandidate]
    public let alreadyFollowed: [FeedRow]
    public let repeated: [FeedRow]
    public private(set) var ticked: Set<String>

    /// Folded title and host of each New row, by id; folded title of each other row, by its section and id.
    private let newKeys: [String: (title: String, host: String)]
    private let followedKeys: [Int: String]
    private let repeatedKeys: [Int: String]

    /// - Parameter startingTicks: the rows ticked when the preview opens; nil ticks every New row. Ids not in New are
    ///   dropped. #4858: pass `preview.defaultSelection`.
    public init(preview: OPMLImportPreview, startingTicks: Set<String>? = nil) {
        newRows = OPMLImportOrder.sorted(preview.toFollow, title: \.title, feedURL: { $0.feed?.url })
        let followedRows = preview.alreadyFollowed.enumerated().map { FeedRow(id: $0.offset, feed: $0.element) }
        alreadyFollowed = OPMLImportOrder.sorted(followedRows, title: \.feed.title, feedURL: \.feed.feedURL)
        let repeatedRows = preview.duplicatesInFile.enumerated().map { FeedRow(id: $0.offset, feed: $0.element) }
        repeated = OPMLImportOrder.sorted(repeatedRows, title: \.feed.title, feedURL: \.feed.feedURL)
        let newIDs = Set(preview.toFollow.map(\.id))
        ticked = startingTicks.map { $0.intersection(newIDs) } ?? newIDs
        var keys: [String: (title: String, host: String)] = [:]
        for row in preview.toFollow {
            keys[row.id] = (OPMLImportOrder.fold(row.title), OPMLImportOrder.fold(row.feed.flatMap { URLComponents(string: $0.url)?.host } ?? ""))
        }
        newKeys = keys
        followedKeys = Dictionary(uniqueKeysWithValues: followedRows.map { ($0.id, OPMLImportOrder.fold($0.feed.title)) })
        repeatedKeys = Dictionary(uniqueKeysWithValues: repeatedRows.map { ($0.id, OPMLImportOrder.fold($0.feed.title)) })
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.newRows == rhs.newRows && lhs.alreadyFollowed == rhs.alreadyFollowed
            && lhs.repeated == rhs.repeated && lhs.ticked == rhs.ticked
    }

    public var tickedCount: Int { ticked.count }
    public var showsSearch: Bool { newRows.count > Self.searchThreshold }
    public var showsBulkButtons: Bool { newRows.count >= 2 }

    public func isTicked(_ id: String) -> Bool { ticked.contains(id) }

    /// The query trimmed of spaces and line breaks, then folded; nil when nothing is left (no search).
    public static func normalizedQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : OPMLImportOrder.fold(trimmed)
    }

    /// New rows match on their title or their feed's host (both show on the row); Already followed and Repeated rows,
    /// which show no host, match on their title only.
    public func matches(_ raw: String) -> Matches {
        guard let query = Self.normalizedQuery(raw) else {
            return Matches(query: nil, new: newRows, alreadyFollowed: alreadyFollowed, repeated: repeated)
        }
        return Matches(
            query: query,
            new: newRows.filter { row in
                guard let key = newKeys[row.id] else { return false }
                return key.title.contains(query) || key.host.contains(query)
            },
            alreadyFollowed: alreadyFollowed.filter { followedKeys[$0.id]?.contains(query) == true },
            repeated: repeated.filter { repeatedKeys[$0.id]?.contains(query) == true }
        )
    }

    /// A shown New row is unticked.
    public func canSelectAll(_ m: Matches) -> Bool { m.new.contains { !ticked.contains($0.id) } }
    /// A shown New row is ticked.
    public func canDeselectAll(_ m: Matches) -> Bool { m.new.contains { ticked.contains($0.id) } }

    /// Ticked rows the search hides; 0 with no search.
    public func hiddenTickedCount(_ m: Matches) -> Int {
        guard m.isSearching else { return 0 }
        let shown = Set(m.new.map(\.id))
        return ticked.subtracting(shown).count
    }

    public mutating func selectAll(_ m: Matches) {
        ticked.formUnion(m.new.map(\.id))
    }

    public mutating func deselectAll(_ m: Matches) {
        ticked.subtract(m.new.map(\.id))
    }

    public mutating func setTicked(_ id: String, _ isOn: Bool) {
        guard newKeys[id] != nil else { return }
        if isOn { ticked.insert(id) } else { ticked.remove(id) }
    }
}
