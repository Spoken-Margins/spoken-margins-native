import Foundation

/// What a Library folder shows about its items (#3769): which are in it right now, where each stands, and the words for the
/// row and the folder screen. Pure, over the folder's record and the Library's rows, so the row, the screen and the play
/// button read one answer. Finished means `ItemFinishedRule` (`LibraryItemRow.isCompleted`); part way means not finished with a
/// continuation percent above 0.
public struct LibraryFolderProgress: Equatable, Sendable {
    public enum ItemState: Equatable, Sendable {
        case notStarted
        case partWay(percent: Int)
        case finished

        /// The word the folder screen always shows beside the glyph, so meaning never rests on colour: "Not started",
        /// "40%", "Finished".
        public var word: String {
            switch self {
            case .notStarted: return "Not started"
            case .partWay(let percent): return "\(percent)%"
            case .finished: return "Finished"
            }
        }

        /// The SF Symbol drawn with the word.
        public var symbol: String {
            switch self {
            case .notStarted: return "circle"
            case .partWay: return "circle.lefthalf.filled"
            case .finished: return "checkmark.circle.fill"
            }
        }
    }

    /// One live item of the folder, numbered in folder order.
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { itemID }
        /// From 1, counting only live items, so it matches the folder screen and the item screen's "3 of 24".
        public var number: Int
        public var memberKey: String
        public var itemID: String
        public var row: LibraryItemRow
        public var state: ItemState
        /// A newer copy of a changed file ("Updated copy").
        public var isUpdatedCopy: Bool

        /// What VoiceOver reads for the row: "3 of 24, Finished, <title>".
        public func accessibilityLabel(of total: Int) -> String {
            "\(number) of \(total), \(state.word), \(row.title)"
        }
    }

    /// The folder's live items in order: members that are added, whose item is in the Library and not in Recently Deleted.
    /// Removed, failed and still-arriving members are not here.
    public let entries: [Entry]
    /// Members still being added.
    public let addingCount: Int
    /// Members the importer has finished with, added or failed. With `addingCount` it makes "Adding 3 of 24…".
    public let processedCount: Int
    /// Files that could not be added: failed members and the walk's named files (packets, repeats, unreadable `.json`).
    public let notAddedCount: Int

    /// - Parameter rows: the Library's rows by item ID. An item that is not a row (deleted, or not yet saved) is not live.
    public init(folder: LibraryFolderRecord, rows: [String: LibraryItemRow]) {
        var entries: [Entry] = []
        var adding = 0
        var processed = 0
        var failed = 0
        for member in folder.members {
            switch member.state {
            case .adding:
                adding += 1
            case .failed:
                failed += 1
                processed += 1
            case .added:
                processed += 1
                guard let itemID = member.itemID, let row = rows[itemID] else { continue }
                entries.append(Entry(
                    number: entries.count + 1, memberKey: member.key, itemID: itemID, row: row,
                    state: Self.state(of: row), isUpdatedCopy: member.updatedCopyOf != nil))
            case .removed:
                break
            }
        }
        self.entries = entries
        addingCount = adding
        processedCount = processed
        notAddedCount = failed + folder.notAdded.count
    }

    public static func state(of row: LibraryItemRow) -> ItemState {
        if row.isCompleted { return .finished }
        if let percent = row.continuationProgressPercent, percent > 0 { return .partWay(percent: percent) }
        return .notStarted
    }

    // MARK: Counts

    public var itemCount: Int { entries.count }
    public var unfinishedCount: Int { entries.filter { $0.state != .finished }.count }
    public var isImporting: Bool { addingCount > 0 }
    public var isEmpty: Bool { entries.isEmpty && addingCount == 0 }
    /// Every live item is finished, and there is at least one.
    public var isAllFinished: Bool { !entries.isEmpty && unfinishedCount == 0 }
    /// The row's ▶ and the folder screen's button wait for the first item.
    public var canPlay: Bool { !entries.isEmpty }
    public var margins: Int { entries.reduce(0) { $0 + $1.row.marginCount } }
    /// Live items with Margins from a friend that the listener has not heard.
    public var itemsWithNewSharedMargins: Int { entries.filter { $0.row.sharedMargins.new > 0 }.count }

    // MARK: Words

    /// The row's detail line:
    ///
    /// | State | Text |
    /// | --- | --- |
    /// | importing | "Adding 3 of 24…" |
    /// | normal | "24 files · 16 unfinished" |
    /// | all finished | "24 files · all finished" |
    /// | failures not cleared | "22 files · 22 unfinished · 2 not added" |
    /// | empty | "Empty folder" |
    /// | every file failed | "3 not added" |
    public var detailLine: String {
        if isImporting { return "Adding \(processedCount) of \(processedCount + addingCount)…" }
        if entries.isEmpty { return notAddedCount > 0 ? Self.notAddedWords(notAddedCount) : "Empty folder" }
        var parts = [Self.itemsWords(itemCount), isAllFinished ? "all finished" : "\(unfinishedCount) unfinished"]
        if notAddedCount > 0 { parts.append(Self.notAddedWords(notAddedCount)) }
        return parts.joined(separator: " · ")
    }

    /// The row's line for the listener's own Margins on the folder's items: "1 Margin", "5 Margins". Nil for none.
    public var marginLine: String? { LibraryRowWording.marginCountLine(margins) }

    /// "New shared Margins in 1 file", "New shared Margins in 3 files". Nil when no item has any.
    public var sharedLine: String? {
        let count = itemsWithNewSharedMargins
        guard count > 0 else { return nil }
        return "New shared Margins in \(count) \(count == 1 ? "file" : "files")"
    }

    /// The row's own VoiceOver label: "Daily Brief, folder, 24 files, 16 unfinished".
    public func accessibilityLabel(folderName: String) -> String {
        if isImporting { return "\(folderName), folder, \(detailLine)" }
        if entries.isEmpty { return "\(folderName), folder, \(detailLine)" }
        let state = isAllFinished ? "all finished" : "\(unfinishedCount) unfinished"
        return "\(folderName), folder, \(Self.itemsWords(itemCount)), \(state)"
    }

    static func itemsWords(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
    static func notAddedWords(_ count: Int) -> String { "\(count) not added" }
}

/// Where a folder's ▶ starts and what it lines up behind it (#3769). The row's ▶, the folder screen's button, the context
/// menu and a row's "Play from here" all read this, so they cannot disagree.
///
/// The start item is the first that applies:
///
/// 1. the unfinished item listened to most recently;
/// 2. otherwise the first unfinished item in order;
/// 3. otherwise the first finished item with new shared Margins;
/// 4. otherwise item 1.
///
/// The queue is the unfinished items after the start item, in order; in case 4 every item after item 1. The caller puts them
/// in front of the play queue with `PlayQueue.playNext(contentsOf:)`, then starts the start item.
public struct LibraryFolderPlayPlan: Equatable, Sendable {
    public enum Label: String, Equatable, Sendable {
        case start = "Start"
        case `continue` = "Continue"
        case playAgain = "Play Again"

        /// What VoiceOver says for an icon-only ▶: "Start Daily Brief", "Continue Daily Brief", "Play Daily Brief again".
        public func accessibilityLabel(folderName: String) -> String {
            switch self {
            case .start: return "Start \(folderName)"
            case .continue: return "Continue \(folderName)"
            case .playAgain: return "Play \(folderName) again"
            }
        }
    }

    public var label: Label
    public var startItemID: String
    /// The folder items to put in front of the queue, in order. Never holds the start item.
    public var queuedItemIDs: [String]

    /// The plan for the folder's own ▶, or nil while it has no live item.
    public static func resume(_ progress: LibraryFolderProgress) -> LibraryFolderPlayPlan? {
        let entries = progress.entries
        guard let first = entries.first else { return nil }
        let unfinished = entries.filter { $0.state != .finished }
        let heard = Self.hasAnyListening(entries)

        let start: LibraryFolderProgress.Entry
        var replaysAll = false
        var startsFinishedItem = false
        if let latest = Self.mostRecentlyListened(unfinished) {
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
        // "Start" only for a folder nobody has listened to; a finished item reopened for friends' Margins is "Continue".
        let label: Label = replaysAll ? .playAgain : ((heard || startsFinishedItem) ? .continue : .start)
        return LibraryFolderPlayPlan(
            label: label, startItemID: start.itemID,
            queuedItemIDs: queue(after: start, in: entries, everyItem: replaysAll))
    }

    /// "Play from here" on one item: it starts, and the unfinished items after it follow. When every item is finished they
    /// all follow, as in a replay. Nil when `itemID` is not a live item of the folder.
    public static func playFrom(itemID: String, _ progress: LibraryFolderProgress) -> LibraryFolderPlayPlan? {
        guard let start = progress.entries.first(where: { $0.itemID == itemID }) else { return nil }
        let replaysAll = progress.isAllFinished
        return LibraryFolderPlayPlan(
            label: replaysAll ? .playAgain : .continue, startItemID: start.itemID,
            queuedItemIDs: queue(after: start, in: progress.entries, everyItem: replaysAll))
    }

    /// The banner after a play: "Playing “Daily Brief” · 23 more in the queue." The number counts only the folder items this
    /// play put in the queue, never what was already waiting.
    public func banner(folderName: String) -> String {
        switch queuedItemIDs.count {
        case 0: return "Playing “\(folderName)”."
        default: return "Playing “\(folderName)” · \(queuedItemIDs.count) more in the queue."
        }
    }

    // MARK: Pieces

    private static func queue(after start: LibraryFolderProgress.Entry, in entries: [LibraryFolderProgress.Entry], everyItem: Bool) -> [String] {
        entries.filter { $0.number > start.number && (everyItem || $0.state != .finished) }.map(\.itemID)
    }

    /// Among `entries`, the one listened to last; a tie goes to the earlier in folder order. Only an item with a listening
    /// time counts.
    private static func mostRecentlyListened(_ entries: [LibraryFolderProgress.Entry]) -> LibraryFolderProgress.Entry? {
        entries.filter { $0.row.lastListenedAt != nil }
            .max { ($0.row.lastListenedAt ?? .distantPast, -$0.number) < ($1.row.lastListenedAt ?? .distantPast, -$1.number) }
    }

    /// "Start" is for a folder nobody has listened to: no listening time, no place saved and no progress on any item.
    private static func hasAnyListening(_ entries: [LibraryFolderProgress.Entry]) -> Bool {
        entries.contains { $0.row.lastListenedAt != nil || $0.row.hasContinuationSession || ($0.row.continuationProgressPercent ?? 0) > 0 }
    }
}
