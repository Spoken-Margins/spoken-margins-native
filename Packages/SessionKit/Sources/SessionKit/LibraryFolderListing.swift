import Foundation

/// A Library folder as one row of the Library list (#3769).
public struct LibraryFolderListRow: Identifiable, Equatable, Sendable {
    /// Distinct from every item id, so a folder row and an item row never share an identity in the list.
    public var id: String { Self.rowID(folderID: folderID) }
    public let folderID: String
    public let name: String
    public let progress: LibraryFolderProgress
    /// When the folder was first picked; where it sorts until its first item has arrived.
    public let importedAt: Date
    /// What the row's ▶ does; nil while no item has arrived, which is when ▶ is disabled.
    public let playPlan: LibraryFolderPlayPlan?

    public static func rowID(folderID: String) -> String { "folder:" + folderID }
}

/// One row of the Library list once folders exist: an item, or a folder standing for its items (#3769).
///
/// `LibraryListEntry` and `LibraryListRows` are unchanged and stay what the screen draws today; PR 7b switches the screen to this.
public enum LibraryListing: Identifiable, Equatable, Sendable {
    case item(LibraryItemRow, isCurrent: Bool)
    case folder(LibraryFolderListRow, isCurrent: Bool)

    public var id: String {
        switch self {
        case .item(let row, _): return row.id
        case .folder(let row, _): return row.id
        }
    }

    public var isCurrent: Bool {
        switch self {
        case .item(_, let isCurrent), .folder(_, let isCurrent): return isCurrent
        }
    }
}

/// Which rows the Library list shows when some items belong to Library folders, and in what order (#3769).
///
/// **Browsing** is no search text and the content type, offline and shared-Margins filters at their defaults. While browsing,
/// a folder's items are not listed on their own: the folder row stands for them. Searching, or any other filter, lists the
/// matching items on their own, each carrying its folder's name (`LibraryItemRow.folderName`) for "· in Daily Brief", and no
/// folder rows, except that while searching a folder whose name matches the text is also listed.
///
/// The Listening filter applies to a folder row as a whole:
///
/// - Unfinished: some item is unfinished or has new shared Margins; the folder is still importing; or nothing was added and
///   some files could not be (so the listener can see what failed).
/// - Unplayed: some item is not started, or the folder is still importing.
/// - In Progress: some item is part way.
/// - Completed: every item is finished, and there is at least one.
/// - All: always, an empty folder included.
///
/// Folders sort by the same rules as items, from these values: Recently Added and Published, the newest add among the
/// folder's items (its import time when none has arrived); Recently Listened, the newest listening among them; Title, the
/// folder's name; Progress, the share of items finished.
///
/// A folder only counts when its record is not deleted and its collection still exists. Items that are not rows (deleted, or
/// not yet saved) are not in the folder as far as the list is concerned. With no folder at all, the answer is exactly what
/// `LibraryQueryEngine` and `LibraryListRows` give today.
public enum LibraryFolderListEngine {
    public static func listing(
        rows: [LibraryItemRow],
        collections: [ItemCollection],
        folders: [LibraryFolderRecord],
        query: LibraryQuery,
        currentItemID: String?
    ) -> [LibraryListing] {
        let live = liveFolders(folders: folders, collections: collections, rows: rows)
        if live.isEmpty {
            return LibraryListRows.entries(visible: LibraryQueryEngine.visibleLibraryItems(rows, query: query), currentId: currentItemID)
                .map { .item($0.row, isCurrent: $0.isCurrent) }
        }

        let folderByItem = itemFolders(live)
        let searching = !trimmed(query.query).isEmpty
        let browsing = isBrowsing(query)
        var entries: [Candidate] = []

        if browsing {
            let loose = rows.filter { folderByItem[$0.id] == nil }
            entries += LibraryQueryEngine.visibleLibraryItems(loose, query: query).map { .item($0) }
            entries += live.filter { matches($0.progress, listening: query.listeningState) }.map { .folder($0) }
        } else {
            var named = rows
            for index in named.indices { named[index].folderName = folderByItem[named[index].id]?.name }
            entries += LibraryQueryEngine.visibleLibraryItems(named, query: query).map { .item($0) }
            if searching, onlySearching(query) {
                let wanted = fold(trimmed(query.query))
                entries += live
                    .filter { fold($0.name).localizedStandardContains(wanted) && matches($0.progress, listening: query.listeningState) }
                    .map { .folder($0) }
            }
        }

        let ordered = entries.sorted { LibraryQueryEngine.areInOrder($0.sortRow, $1.sortRow, sort: query.sort) }
        return placingCurrent(ordered, currentItemID: currentItemID, folderByItem: folderByItem, browsing: browsing)
    }

    /// Whether the default view has nothing left to do (#4178's "caught up"), with a folder counted as one row. The same
    /// conditions as `LibraryQueryEngine.libraryIsCaughtUp`.
    public static func isCaughtUp(
        rows: [LibraryItemRow], collections: [ItemCollection], folders: [LibraryFolderRecord], query: LibraryQuery
    ) -> Bool {
        let live = liveFolders(folders: folders, collections: collections, rows: rows)
        let inFolder = itemFolders(live)
        let loose = rows.filter { inFolder[$0.id] == nil }
        let standing = loose.map(\.staysInUnfinished) + live.map { matches($0.progress, listening: .unfinished) }
        return !standing.isEmpty && standing.allSatisfy { !$0 }
            && query.listeningState == .unfinished && isBrowsing(query)
    }

    /// `LibraryQueryEngine.addedItemVisibility`, with the folder case first: an item inside a folder is not a row of its own
    /// while browsing, and the answer says so, so "Added to Library" is never unexplained.
    public static func addedItemVisibility(
        itemId: String, rows: [LibraryItemRow], collections: [ItemCollection], folders: [LibraryFolderRecord], query: LibraryQuery
    ) -> String {
        let live = liveFolders(folders: folders, collections: collections, rows: rows)
        if isBrowsing(query), itemFolders(live)[itemId] != nil { return "hidden:in_folder" }
        let answer = LibraryQueryEngine.addedItemVisibility(itemId: itemId, in: rows, query: query)
        // The reasons an item is hidden are the same with or without folders. Where a visible item stands is not: a folder's
        // items are not rows and a folder is one, so the position is read from the list the screen draws.
        guard !live.isEmpty, answer.hasPrefix("visible:") else { return answer }
        let position = listing(rows: rows, collections: collections, folders: folders, query: query, currentItemID: nil)
            .firstIndex { $0.id == itemId } ?? 0
        return "visible:row_\(position + 1)"
    }

    /// The row's detail line with the folder's name on the end: "12 min · in Daily Brief". Unchanged for an item in no folder.
    public static func detailLine(_ detail: String, folderName: String?) -> String {
        guard let folderName, !folderName.isEmpty else { return detail }
        return detail.isEmpty ? "in \(folderName)" : "\(detail) · in \(folderName)"
    }

    // MARK: - Pieces

    /// Whether a folder row is listed under a Listening filter.
    static func matches(_ progress: LibraryFolderProgress, listening: LibraryListeningStateFilter) -> Bool {
        switch listening {
        case .all:
            return true
        case .unfinished:
            return progress.isImporting || progress.unfinishedCount > 0 || progress.itemsWithNewSharedMargins > 0
                || (progress.entries.isEmpty && progress.notAddedCount > 0)
        case .unplayed:
            return progress.isImporting || progress.entries.contains { $0.state == .notStarted }
        case .inProgress:
            return progress.entries.contains { if case .partWay = $0.state { true } else { false } }
        case .completed:
            return progress.isAllFinished
        }
    }

    static func isBrowsing(_ query: LibraryQuery) -> Bool {
        trimmed(query.query).isEmpty && query.contentType == .all && query.offlineState == .all && query.sharedMargins == .all
    }

    /// Search text with every other filter at its default.
    private static func onlySearching(_ query: LibraryQuery) -> Bool {
        query.contentType == .all && query.offlineState == .all && query.sharedMargins == .all
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func liveFolders(
        folders: [LibraryFolderRecord], collections: [ItemCollection], rows: [LibraryItemRow]
    ) -> [LibraryFolderListRow] {
        guard !folders.isEmpty else { return [] }
        let names = Dictionary(collections.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return folders
            .filter { !$0.isTrashed }
            .sorted { ($0.importedAt, $0.id) < ($1.importedAt, $1.id) }
            .compactMap { folder -> LibraryFolderListRow? in
                guard let name = names[folder.id] else { return nil } // an orphan: the launch rule drops it
                let progress = LibraryFolderProgress(folder: folder, rows: rowsByID)
                return LibraryFolderListRow(folderID: folder.id, name: name, progress: progress, importedAt: folder.importedAt,
                                            playPlan: LibraryFolderPlayPlan.resume(progress))
            }
    }

    /// Which folder each live item is in; an item in two (which only an older build could arrange) belongs to the older.
    private static func itemFolders(_ folders: [LibraryFolderListRow]) -> [String: LibraryFolderListRow] {
        var result: [String: LibraryFolderListRow] = [:]
        for folder in folders {
            for entry in folder.progress.entries where result[entry.itemID] == nil { result[entry.itemID] = folder }
        }
        return result
    }

    private static func placingCurrent(
        _ ordered: [Candidate], currentItemID: String?, folderByItem: [String: LibraryFolderListRow], browsing: Bool
    ) -> [LibraryListing] {
        var currentIndex: Int?
        if let currentItemID {
            if browsing, let folder = folderByItem[currentItemID] {
                currentIndex = ordered.firstIndex { if case .folder(let row) = $0 { row.folderID == folder.folderID } else { false } }
            } else {
                currentIndex = ordered.firstIndex { if case .item(let row) = $0 { row.id == currentItemID } else { false } }
            }
        }
        var listing = ordered.enumerated().map { index, candidate in candidate.listing(isCurrent: index == currentIndex) }
        if let currentIndex { listing.insert(listing.remove(at: currentIndex), at: 0) }
        return listing
    }

    private enum Candidate {
        case item(LibraryItemRow)
        case folder(LibraryFolderListRow)

        func listing(isCurrent: Bool) -> LibraryListing {
            switch self {
            case .item(let row): return .item(row, isCurrent: isCurrent)
            case .folder(let row): return .folder(row, isCurrent: isCurrent)
            }
        }

        var sortRow: SortRow {
            switch self {
            case .item(let row): return SortRow(item: row)
            case .folder(let row): return SortRow(folder: row)
            }
        }
    }

    /// The values the Library sorts on, for an item or for a folder, so both go through `LibraryQueryEngine.areInOrder`.
    struct SortRow: LibraryQueryRow {
        var id: String
        var title: String
        var sourceTitle: String? { nil }
        var author: String? { nil }
        var mediaType: String { "text" }
        var sourceReference: String? { nil }
        var sourceReferenceType: String? { nil }
        var isCompleted: Bool
        var continuationProgressPercent: Int?
        var offlineState: LibraryOfflineStateFilter { .all }
        var addedAt: Date?
        var publishedAt: Date?
        var lastListenedAt: Date?
        var storageRecencyRank: Int
        var sharedMargins: SharedMarginTally
        var friendMarginsArrivedAt: Date?

        init(item row: LibraryItemRow) {
            id = row.id
            title = row.title
            isCompleted = row.isCompleted
            continuationProgressPercent = row.continuationProgressPercent
            addedAt = row.addedAt
            publishedAt = row.publishedAt
            lastListenedAt = row.lastListenedAt
            storageRecencyRank = row.storageRecencyRank
            sharedMargins = row.sharedMargins
            friendMarginsArrivedAt = row.friendMarginsArrivedAt
        }

        init(folder row: LibraryFolderListRow) {
            let entries = row.progress.entries
            id = row.id
            title = row.name
            isCompleted = row.progress.isAllFinished
            continuationProgressPercent = entries.isEmpty ? 0 : entries.filter { $0.state == .finished }.count * 100 / entries.count
            let newest = entries.compactMap { $0.row.recentlyAddedDate }.max()
            addedAt = newest ?? row.importedAt // a folder still waiting for its first item is new
            publishedAt = addedAt
            lastListenedAt = entries.compactMap(\.row.lastListenedAt).max()
            storageRecencyRank = entries.map(\.row.storageRecencyRank).min() ?? 0
            let count = row.progress.itemsWithNewSharedMargins
            sharedMargins = SharedMarginTally(total: count, new: count)
            friendMarginsArrivedAt = nil
        }
    }
}
