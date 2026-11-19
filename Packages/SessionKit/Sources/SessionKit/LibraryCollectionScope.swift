import Foundation

/// Narrowing the Library by a collection (#4343, PR 1 of the Design). The Library's chip row picks an
/// `ItemCollectionScope`, the same type the Margins tab already narrows by, so one collection means the same items on
/// both tabs.
///
/// "Items" here are the Library's own rows, which leave out Recently Deleted. `ItemCollection` keeps the ids of members
/// that were deleted (its doc comment), so a collection's size is always counted against the rows, never from
/// `itemIDs.count`. A restored item is a row again and counts again.
public enum LibraryCollectionScope {
    /// The rows in the selected collection, in the rows' own order. `nil` is All.
    public static func rows<Row: LibraryQueryRow>(_ rows: [Row], in selection: ItemCollectionScope?) -> [Row] {
        guard let selection else { return rows }
        return rows.filter { selection.contains(itemID: $0.id) }
    }

    /// What the Library lists: the selected collection's rows, then the existing filter, sort and search. Search
    /// narrows inside the collection and never past it (Design default 5).
    public static func visibleLibraryItems<Row: LibraryQueryRow>(
        _ rows: [Row],
        query: LibraryQuery,
        in selection: ItemCollectionScope?
    ) -> [Row] {
        LibraryQueryEngine.visibleLibraryItems(Self.rows(rows, in: selection), query: query)
    }

    /// How many Library rows a collection holds: members that are in Recently Deleted are not rows, so they are not
    /// counted, and completed items are, whatever the listening filter says.
    public static func itemCount<Row: LibraryQueryRow>(in collection: ItemCollection, among rows: [Row]) -> Int {
        let members = ItemCollectionScope(collection)
        return rows.reduce(0) { $0 + (members.contains(itemID: $1.id) ? 1 : 0) }
    }

    /// The selection after the collections changed: the same collection with its current members, or `nil` (All) when
    /// it was deleted, so nobody is left looking at a Library that seems to be missing items.
    public static func selection(
        _ current: ItemCollectionScope?,
        afterCollectionsChanged collections: [ItemCollection]
    ) -> ItemCollectionScope? {
        guard let current else { return nil }
        return collections.first { $0.id == current.collectionID }.map(ItemCollectionScope.init)
    }

    /// The chips after All: collections in alphabetical order, localized and case-insensitive, ties by id so the
    /// order never shuffles between launches (Design: "alphabetical").
    public static func chipOrder(_ collections: [ItemCollection]) -> [ItemCollection] {
        collections.sorted { lhs, rhs in
            let ordered = lhs.name.localizedStandardCompare(rhs.name)
            return ordered == .orderedSame ? lhs.id < rhs.id : ordered == .orderedAscending
        }
    }

    /// What the Library body is with this selection (#4343): the existing states, plus "Nothing in HIST 210 yet." for an
    /// empty collection. "Caught up" is read over the collection's own rows, so a collection of finished readings shows
    /// the Library's finished state and its Show completed button, never the empty-collection state.
    public static func screenState<Row: LibraryQueryRow>(
        accessError: String?,
        rows: [Row],
        query: LibraryQuery,
        in selection: ItemCollectionScope?
    ) -> LibraryScreenState {
        let scoped = Self.rows(rows, in: selection)
        return LibraryScreenState.resolve(
            accessError: accessError,
            itemCount: rows.count,
            isCaughtUp: LibraryQueryEngine.libraryIsCaughtUp(scoped, query: query),
            visibleCount: LibraryQueryEngine.visibleLibraryItems(scoped, query: query).count,
            collectionItemCount: selection == nil ? nil : scoped.count)
    }

    /// What a chip says to VoiceOver: "Collection, HIST 210, selected, 12 items", and "All items" for All (Design).
    public static func chipAccessibilityLabel(name: String?, itemCount: Int, isSelected: Bool) -> String {
        guard let name else { return isSelected ? "All items, selected" : "All items" }
        let items = itemCount == 1 ? "1 item" : "\(itemCount) items"
        return "Collection, \(name), " + (isSelected ? "selected, " : "") + items
    }

    /// The rows the New collection and Edit Items checklist offers: every Library row, completed ones too, narrowed by
    /// the sheet's search with the Library's own matching (title, source, author). The Library's order is kept.
    public static func checklistRows<Row: LibraryQueryRow>(_ rows: [Row], search: String) -> [Row] {
        LibraryQueryEngine.visibleLibraryItems(rows, query: LibraryQuery(query: search, listeningState: .all), includingSenders: false)
    }

    /// A chip tap: the collection with that id, or `nil` (All) when there is none.
    public static func selection(collectionID: String?, in collections: [ItemCollection]) -> ItemCollectionScope? {
        guard let collectionID else { return nil }
        return collections.first { $0.id == collectionID }.map(ItemCollectionScope.init)
    }
}

/// When the Library shows its chip row (Design default 3): once any collection exists, or from 15 items, about a week
/// of a course's readings. The count is the Library's rows, completed ones included and Recently Deleted left out.
public enum CollectionChipRule {
    public static let itemThreshold = 15

    /// `itemCount` is the number of Library rows, which the caller reads after Recently Deleted is left out.
    public static func showsRow(itemCount: Int, collectionCount: Int) -> Bool {
        collectionCount > 0 || itemCount >= itemThreshold
    }
}
