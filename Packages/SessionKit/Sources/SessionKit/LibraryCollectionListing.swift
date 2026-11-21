import Foundation

/// The Library's view choice (#3769, owner's decision 2026-11-19): **Collections** shows each collection as one row and
/// only the items in no collection on their own; **All Items** is the flat list the Library has always shown.
public enum LibraryViewMode: String, CaseIterable, Identifiable, Sendable {
    case collections
    case allItems

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .collections: return "Collections"
        case .allItems: return "All Items"
        }
    }

    public static let defaultsKey = "libraryViewMode"

    /// The saved choice; Collections when none was saved. With no collection the two views list the same rows, so a
    /// listener who never makes one sees no change.
    public static func load(defaults: UserDefaults) -> LibraryViewMode {
        LibraryViewMode(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .collections
    }

    public func save(defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// A collection as one row of the Library list (#3769), shaped like a Following show row: a tile, the name, a count,
/// ▶ Play all and ›.
public struct LibraryCollectionRow: Identifiable, Equatable, Sendable {
    /// Distinct from every item id, so a collection row and an item row never share an identity in the list.
    public var id: String { Self.rowID(collectionID: progress.collectionID) }
    public var collectionID: String { progress.collectionID }
    public var name: String { progress.name }
    public let progress: LibraryCollectionProgress
    /// When the collection was made; where an empty collection sorts.
    public let createdAt: Date
    /// What the row's ▶ does; nil while the collection has no live item, which is when ▶ is disabled.
    public let playPlan: LibraryCollectionPlayPlan?
    /// Made from an imported folder or link list, so the screen can say where it came from.
    public let isImported: Bool

    public static func rowID(collectionID: String) -> String { "collection:" + collectionID }
}

/// One row of the Library list in Collections view: an item, or a collection standing for its items (#3769). Named apart
/// from the folder listing's `LibraryListing` until that listing is retired (owner, 2026-11-20).
public enum LibraryCollectionEntry: Identifiable, Equatable, Sendable {
    case item(LibraryItemRow, isCurrent: Bool)
    case collection(LibraryCollectionRow, isCurrent: Bool)

    public var id: String {
        switch self {
        case .item(let row, _): return row.id
        case .collection(let row, _): return row.id
        }
    }

    public var isCurrent: Bool {
        switch self {
        case .item(_, let isCurrent), .collection(_, let isCurrent): return isCurrent
        }
    }

    /// The item, for an item row.
    public var itemRow: LibraryItemRow? {
        if case .item(let row, _) = self { return row }
        return nil
    }
}

/// Which rows the Library list shows, and in what order, in either view (#3769).
///
/// **All Items** lists exactly the rows `LibraryQueryEngine` and `LibraryListRows` give, as before collections had rows;
/// each row in a collection carries its collections' names for "· in Daily Brief".
///
/// **Collections**, while **browsing** (no search text; content type, offline and shared-Margins filters at their
/// defaults): every collection is one row, and an item in any collection is not listed on its own. An item in two
/// collections counts in both. Collections come first, ordered among themselves by the Library's sort, then the loose
/// items in the Library's order, as Files keeps folders on top. The Listening filter asks each collection as a whole:
///
/// - Unfinished: some item is unfinished or has new shared Margins; it is still importing; it is empty; or nothing was
///   added and some files could not be (so the listener can see what failed).
/// - Unplayed: some item is not started, or it is still importing.
/// - In Progress: some item is part way.
/// - Completed: every item is finished, and there is at least one.
/// - All: always.
///
/// **Searching, or any other filter**, in Collections view: matching items are listed on their own, each carrying the
/// names of its collections for "· in Daily Brief", and no collection rows, except that a search with no other filter
/// also lists, first, each collection whose name matches.
///
/// The Continue item stays first: in its own row, or, when it is inside a listed collection, that collection's row,
/// marked current.
public enum LibraryCollectionListEngine {
    public static func listing(
        rows: [LibraryItemRow],
        collections: [ItemCollection],
        imported: [LibraryFolderRecord] = [],
        query: LibraryQuery,
        mode: LibraryViewMode,
        currentItemID: String?
    ) -> [LibraryCollectionEntry] {
        let collectionRows = collections.isEmpty ? [] : self.collectionRows(rows: rows, collections: collections, imported: imported)
        let namesByItem = collectionNames(collectionRows)
        guard mode == .collections, !collectionRows.isEmpty else {
            // The same rows in the same order as before collections had rows; each one only gains "· in X" (#3769).
            return LibraryListRows.entries(visible: LibraryQueryEngine.visibleLibraryItems(rows, query: query), currentId: currentItemID)
                .map { entry in
                    var row = entry.row
                    row.collectionNames = namesByItem[row.id] ?? []
                    return .item(row, isCurrent: entry.isCurrent)
                }
        }
        let browsing = isBrowsing(query)
        var listedCollections: [LibraryCollectionRow] = []
        var items: [LibraryItemRow]

        if browsing {
            listedCollections = collectionRows.filter { matches($0.progress, listening: query.listeningState) }
            items = LibraryQueryEngine.visibleLibraryItems(rows.filter { namesByItem[$0.id] == nil }, query: query)
        } else {
            var named = rows
            for index in named.indices { named[index].collectionNames = namesByItem[named[index].id] ?? [] }
            items = LibraryQueryEngine.visibleLibraryItems(named, query: query)
            if onlySearching(query) {
                let wanted = fold(trimmed(query.query))
                listedCollections = collectionRows.filter {
                    fold($0.name).localizedStandardContains(wanted) && matches($0.progress, listening: query.listeningState)
                }
            }
        }
        listedCollections.sort { LibraryQueryEngine.areInOrder(SortRow(collection: $0), SortRow(collection: $1), sort: query.sort) }

        var listing = listedCollections.map { LibraryCollectionEntry.collection($0, isCurrent: false) }
            + items.map { LibraryCollectionEntry.item($0, isCurrent: false) }
        if let currentItemID, let index = currentIndex(in: listing, currentItemID: currentItemID, browsing: browsing) {
            var current = listing.remove(at: index)
            switch current {
            case .item(let row, _): current = .item(row, isCurrent: true)
            case .collection(let row, _): current = .collection(row, isCurrent: true)
            }
            listing.insert(current, at: 0)
        }
        return listing
    }

    /// Every collection as a row, alphabetical (localized, case-insensitive, ties by id), for pickers such as Add to
    /// Collection and the Margins tab's scope. A collection whose import record says it was deleted is left out.
    public static func collectionRows(
        rows: [LibraryItemRow], collections: [ItemCollection], imported: [LibraryFolderRecord] = []
    ) -> [LibraryCollectionRow] {
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let records = Dictionary(imported.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return LibraryCollectionScope.chipOrder(collections).compactMap { collection in
            let record = records[collection.id]
            if record?.isTrashed == true { return nil }
            let progress = LibraryCollectionProgress(collection: collection, imported: record, rows: rowsByID)
            return LibraryCollectionRow(progress: progress, createdAt: collection.createdAt,
                                        playPlan: LibraryCollectionPlayPlan.resume(progress), isImported: record != nil)
        }
    }

    /// Whether the default view has nothing left to do (#4178's "caught up"), with a collection counted as one row.
    public static func isCaughtUp(
        rows: [LibraryItemRow], collections: [ItemCollection], imported: [LibraryFolderRecord] = [], query: LibraryQuery,
        mode: LibraryViewMode
    ) -> Bool {
        let collectionRows = mode == .collections ? self.collectionRows(rows: rows, collections: collections, imported: imported) : []
        guard !collectionRows.isEmpty else { return LibraryQueryEngine.libraryIsCaughtUp(rows, query: query) }
        let inCollection = collectionNames(collectionRows)
        let standing = rows.filter { inCollection[$0.id] == nil }.map(\.staysInUnfinished)
            + collectionRows.map { matches($0.progress, listening: .unfinished) }
        return !standing.isEmpty && standing.allSatisfy { !$0 } && query.listeningState == .unfinished && isBrowsing(query)
    }

    /// `LibraryQueryEngine.addedItemVisibility`, with the collection case first: an item inside a collection is not a row
    /// of its own while browsing the Collections view, and the answer says so, so "Added to Library" is never unexplained.
    public static func addedItemVisibility(
        itemId: String, rows: [LibraryItemRow], collections: [ItemCollection], query: LibraryQuery, mode: LibraryViewMode
    ) -> String {
        if mode == .collections, isBrowsing(query), collections.contains(where: { $0.itemIDs.contains(itemId) }),
           rows.contains(where: { $0.id == itemId }) {
            return "hidden:in_collection"
        }
        return LibraryQueryEngine.addedItemVisibility(itemId: itemId, in: rows, query: query)
    }

    /// The row's detail line with its collections on the end: "12 min · in Daily Brief", "12 min · in Daily Brief and 1
    /// other". Unchanged for an item in no collection.
    public static func detailLine(_ detail: String, collectionNames names: [String]) -> String {
        guard let first = names.first else { return detail }
        let place = names.count == 1 ? "in \(first)" : "in \(first) and \(names.count - 1) \(names.count == 2 ? "other" : "others")"
        return detail.isEmpty ? place : "\(detail) · \(place)"
    }

    // MARK: - Pieces

    /// Whether a collection row is listed under a Listening filter.
    static func matches(_ progress: LibraryCollectionProgress, listening: LibraryListeningStateFilter) -> Bool {
        switch listening {
        case .all:
            return true
        case .unfinished:
            return progress.isImporting || progress.unfinishedCount > 0 || progress.itemsWithNewSharedMargins > 0
                || progress.entries.isEmpty
        case .unplayed:
            return progress.isImporting || progress.entries.contains { $0.state == .notStarted }
        case .inProgress:
            return progress.entries.contains { if case .partWay = $0.state { true } else { false } }
        case .completed:
            return progress.isAllFinished
        }
    }

    static func isBrowsing(_ query: LibraryQuery) -> Bool {
        trimmed(query.query).isEmpty && onlySearching(query)
    }

    /// Every filter but the search text and the Listening filter at its default.
    private static func onlySearching(_ query: LibraryQuery) -> Bool {
        query.contentType == .all && query.offlineState == .all && query.sharedMargins == .all
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// The names of the collections each live item is in, alphabetical.
    private static func collectionNames(_ rows: [LibraryCollectionRow]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for row in rows {
            for entry in row.progress.entries { result[entry.itemID, default: []].append(row.name) }
        }
        return result
    }

    private static func currentIndex(in listing: [LibraryCollectionEntry], currentItemID: String, browsing: Bool) -> Int? {
        if let index = listing.firstIndex(where: { $0.itemRow?.id == currentItemID }) { return index }
        guard browsing else { return nil }
        return listing.firstIndex {
            if case .collection(let row, _) = $0 { return row.progress.entries.contains { $0.itemID == currentItemID } }
            return false
        }
    }

    /// The values the Library sorts on, for a collection, so it goes through `LibraryQueryEngine.areInOrder`.
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

        /// Recently Added and Published: the newest add among its items (when it was made, while empty). Recently
        /// Listened: the newest listening among them. Title: its name. Progress: the share of items finished.
        init(collection row: LibraryCollectionRow) {
            let entries = row.progress.entries
            id = row.id
            title = row.name
            isCompleted = row.progress.isAllFinished
            continuationProgressPercent = entries.isEmpty ? 0 : entries.filter { $0.state == .finished }.count * 100 / entries.count
            addedAt = entries.compactMap { $0.row.recentlyAddedDate }.max() ?? row.createdAt
            publishedAt = addedAt
            lastListenedAt = entries.compactMap(\.row.lastListenedAt).max()
            storageRecencyRank = entries.map(\.row.storageRecencyRank).min() ?? 0
        }
    }
}
