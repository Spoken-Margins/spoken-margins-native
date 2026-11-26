import Foundation

/// What a collection shows about its items (#3769, owner's decision 2026-11-19): which are in it right now, where each
/// stands, and the words for its Library row and its own screen. Pure, over the collection, the record of an imported
/// folder or link list when there is one, and the Library's rows, so the row, the screen and Play all read one answer.
///
/// The collection's `itemIDs` are its members and its order. An item may be in several collections. Members that are not
/// Library rows (in Recently Deleted, or not saved yet) are not live and are not counted; restoring one brings it back
/// in its old place. Finished means `ItemFinishedRule` (`LibraryItemRow.isCompleted`); part way means not finished with a
/// continuation percent above 0.
public struct LibraryCollectionProgress: Equatable, Sendable {
    public enum ItemState: Equatable, Sendable {
        case notStarted
        case partWay(percent: Int)
        case finished

        /// The word always shown beside the glyph, so meaning never rests on colour: "Not started", "40%", "Finished".
        public var word: String {
            switch self {
            case .notStarted: return "Not started"
            case .partWay(let percent): return "\(percent)%"
            case .finished: return "Finished"
            }
        }

        /// The SF Symbol drawn with the word. Shape differs per state (empty, half, ticked), never only colour.
        public var symbol: String {
            switch self {
            case .notStarted: return "circle"
            case .partWay: return "circle.lefthalf.filled"
            case .finished: return "checkmark.circle.fill"
            }
        }
    }

    /// One live item of the collection, numbered in the collection's order.
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { itemID }
        /// From 1, counting only live items.
        public var number: Int
        public var itemID: String
        public var row: LibraryItemRow
        public var state: ItemState

        /// What VoiceOver reads for the row on the collection's screen: "3 of 24, Finished, <title>".
        public func accessibilityLabel(of total: Int) -> String {
            "\(number) of \(total), \(state.word), \(row.title)"
        }
    }

    public let collectionID: String
    public let name: String
    /// The collection's live items, in its order.
    public let entries: [Entry]
    /// Files or links of an imported folder or list still being added.
    public let addingCount: Int
    /// Files or links the importer has finished with, added or failed. With `addingCount` it makes "Adding 3 of 24…".
    public let processedCount: Int
    /// Files or links of an import that could not be added.
    public let notAddedCount: Int

    /// - Parameters:
    ///   - imported: the record of the folder or link list this collection was imported from, if any (same ID). A deleted
    ///     record is ignored.
    ///   - rows: the Library's rows by item ID. An item that is not a row is not live.
    public init(collection: ItemCollection, imported: LibraryFolderRecord? = nil, rows: [String: LibraryItemRow]) {
        collectionID = collection.id
        name = collection.name
        var entries: [Entry] = []
        for itemID in collection.itemIDs {
            guard let row = rows[itemID] else { continue }
            entries.append(Entry(number: entries.count + 1, itemID: itemID, row: row, state: Self.state(of: row)))
        }
        self.entries = entries
        var adding = 0
        var processed = 0
        var failed = 0
        if let imported, !imported.isTrashed, imported.id == collection.id {
            for member in imported.members {
                switch member.state {
                case .adding: adding += 1
                case .failed: failed += 1; processed += 1
                case .added: processed += 1
                case .removed: break
                }
            }
            failed += imported.notAdded.count
        }
        addingCount = adding
        processedCount = processed
        notAddedCount = failed
    }

    public static func state(of row: LibraryItemRow) -> ItemState {
        if row.isCompleted { return .finished }
        if let percent = row.continuationProgressPercent, percent > 0 { return .partWay(percent: percent) }
        return .notStarted
    }

    // MARK: Counts

    public var itemCount: Int { entries.count }
    public var itemIDs: [String] { entries.map(\.itemID) }
    public var unfinishedCount: Int { entries.filter { $0.state != .finished }.count }
    public var isImporting: Bool { addingCount > 0 }
    /// Every live item is finished, and there is at least one.
    public var isAllFinished: Bool { !entries.isEmpty && unfinishedCount == 0 }
    /// Play all and Add to Queue wait for the first item.
    public var canPlay: Bool { !entries.isEmpty }
    public var margins: Int { entries.reduce(0) { $0 + $1.row.marginCount } }
    /// Live items with Margins from a friend that the listener has not heard.
    public var itemsWithNewSharedMargins: Int { entries.filter { $0.row.sharedMargins.new > 0 }.count }

    // MARK: Words

    /// The row's detail line, one line, the Following show row's shape:
    ///
    /// | State | Text |
    /// | --- | --- |
    /// | importing | "Adding 3 of 24…" |
    /// | normal | "24 items · 16 unfinished" |
    /// | all finished | "24 items · all finished" |
    /// | failures | "22 items · 22 unfinished · 2 not added" |
    /// | empty | "No items" |
    /// | every file failed | "3 not added" |
    public var detailLine: String {
        if isImporting { return "Adding \(processedCount) of \(processedCount + addingCount)…" }
        if entries.isEmpty { return notAddedCount > 0 ? Self.notAddedWords(notAddedCount) : "No items" }
        var parts = [Self.itemsWords(itemCount), isAllFinished ? "all finished" : "\(unfinishedCount) unfinished"]
        if notAddedCount > 0 { parts.append(Self.notAddedWords(notAddedCount)) }
        return parts.joined(separator: " · ")
    }

    /// The listener's own Margins on the collection's items: "1 Margin", "5 Margins". Nil for none.
    public var marginLine: String? { LibraryRowWording.marginCountLine(margins) }

    /// "New shared Margins in 1 item", "New shared Margins in 3 items". Nil when no item has any.
    public var sharedLine: String? {
        let count = itemsWithNewSharedMargins
        guard count > 0 else { return nil }
        return "New shared Margins in \(count) \(count == 1 ? "item" : "items")"
    }

    /// The row's own VoiceOver label: "Daily Brief, collection, 24 items, 16 unfinished".
    public var accessibilityLabel: String {
        "\(name), collection, " + detailLine.replacingOccurrences(of: " · ", with: ", ")
    }

    static func itemsWords(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
    static func notAddedWords(_ count: Int) -> String { "\(count) not added" }
}

/// Where a collection's Play all starts and what it lines up behind it (#3769). The row's ▶, the collection screen's
/// button and a row's "Play from Here" all read this, so they cannot disagree.
///
/// The start item is the first that applies:
///
/// 1. the unfinished item listened to most recently;
/// 2. otherwise the first unfinished item in order;
/// 3. otherwise the first finished item with new shared Margins;
/// 4. otherwise item 1.
///
/// The queue is the unfinished items after the start item, in order; in case 4 every item after item 1. The caller puts
/// them in front of the play queue with `PlayQueue.playNext(contentsOf:)`, then starts the start item, so what was
/// already queued stays behind them.
public struct LibraryCollectionPlayPlan: Equatable, Sendable {
    public enum Label: String, Equatable, Sendable {
        case start = "Play All"
        case `continue` = "Continue"
        case playAgain = "Play Again"

        /// What VoiceOver says for an icon-only ▶: "Play all of Daily Brief", "Continue Daily Brief", "Play Daily Brief
        /// again".
        public func accessibilityLabel(name: String) -> String {
            switch self {
            case .start: return "Play all of \(name)"
            case .continue: return "Continue \(name)"
            case .playAgain: return "Play \(name) again"
            }
        }
    }

    public var label: Label
    public var startItemID: String
    /// The collection's items to put in front of the queue, in order. Never holds the start item.
    public var queuedItemIDs: [String]

    /// The plan for the collection's own ▶, or nil while it has no live item.
    public static func resume(_ progress: LibraryCollectionProgress) -> LibraryCollectionPlayPlan? {
        let entries = progress.entries
        guard let first = entries.first else { return nil }
        let unfinished = entries.filter { $0.state != .finished }
        let start: LibraryCollectionProgress.Entry
        var replaysAll = false
        var startsFinishedItem = false
        if let latest = mostRecentlyListened(unfinished) {
            start = latest
        } else if let firstUnfinished = unfinished.first {
            start = firstUnfinished
        } else if let withNewMargins = entries.first(where: { $0.row.sharedMargins.new > 0 }) {
            start = withNewMargins
            startsFinishedItem = true
        } else {
            start = first
            replaysAll = true
        }
        let label: Label = replaysAll ? .playAgain : ((hasAnyListening(entries) || startsFinishedItem) ? .continue : .start)
        return LibraryCollectionPlayPlan(
            label: label, startItemID: start.itemID,
            queuedItemIDs: queue(after: start, in: entries, everyItem: replaysAll))
    }

    /// "Play from Here" on one item: it starts, and the unfinished items after it follow. When every item is finished they
    /// all follow, as in a replay. Nil when `itemID` is not a live item of the collection.
    public static func playFrom(itemID: String, _ progress: LibraryCollectionProgress) -> LibraryCollectionPlayPlan? {
        guard let start = progress.entries.first(where: { $0.itemID == itemID }) else { return nil }
        let replaysAll = progress.isAllFinished
        return LibraryCollectionPlayPlan(
            label: replaysAll ? .playAgain : .continue, startItemID: start.itemID,
            queuedItemIDs: queue(after: start, in: progress.entries, everyItem: replaysAll))
    }

    /// The banner after a play: "Playing “Daily Brief” · 23 more in the queue." The number counts only the collection's
    /// items this play put in the queue, never what was already waiting.
    public func banner(name: String) -> String {
        queuedItemIDs.isEmpty ? "Playing “\(name)”." : "Playing “\(name)” · \(queuedItemIDs.count) more in the queue."
    }

    private static func queue(
        after start: LibraryCollectionProgress.Entry, in entries: [LibraryCollectionProgress.Entry], everyItem: Bool
    ) -> [String] {
        entries.filter { $0.number > start.number && (everyItem || $0.state != .finished) }.map(\.itemID)
    }

    /// Among `entries`, the one listened to last; a tie goes to the earlier in order.
    private static func mostRecentlyListened(_ entries: [LibraryCollectionProgress.Entry]) -> LibraryCollectionProgress.Entry? {
        entries.filter { $0.row.lastListenedAt != nil }
            .max { ($0.row.lastListenedAt ?? .distantPast, -$0.number) < ($1.row.lastListenedAt ?? .distantPast, -$1.number) }
    }

    /// "Play All" is for a collection nobody has listened to: no listening time, no place saved, no progress on any item.
    private static func hasAnyListening(_ entries: [LibraryCollectionProgress.Entry]) -> Bool {
        entries.contains { $0.row.lastListenedAt != nil || $0.row.hasContinuationSession || ($0.row.continuationProgressPercent ?? 0) > 0 }
    }
}

/// A collection's Add to Queue (#3769): its unfinished items, in order, at the end of the queue; when every item is
/// finished, all of them. Items already queued keep their place and are not counted.
public enum LibraryCollectionQueueing {
    public static func itemsToQueue(_ progress: LibraryCollectionProgress) -> [String] {
        progress.isAllFinished ? progress.itemIDs : progress.entries.filter { $0.state != .finished }.map(\.itemID)
    }

    /// "Added 6 from “FourSight” to the queue." / "Everything in “FourSight” is already in the queue."
    public static func banner(added: Int, name: String) -> String {
        guard added > 0 else { return "Everything in “\(name)” is already in the queue." }
        return "Added \(added) from “\(name)” to the queue."
    }
}
