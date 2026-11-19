import Foundation

/// The Library's Select mode (#4720): which rows are ticked, as Mail, Files and Photos do it. Select works on the rows the
/// current view shows; the view's filter, search or collection decides the set, never a separate picker. Only item rows
/// can be ticked: a collection row in the Collections view stays a way in, not a thing to tick.
///
/// The ticked ids are kept in a set and read back in the view's order, so Add to Queue and Add to Collection keep the
/// order the listener sees.
public struct LibrarySelection: Equatable, Sendable {
    public private(set) var selectedIDs: Set<String> = []

    public init(selectedIDs: Set<String> = []) {
        self.selectedIDs = selectedIDs
    }

    public var count: Int { selectedIDs.count }
    public var isEmpty: Bool { selectedIDs.isEmpty }
    public func contains(_ id: String) -> Bool { selectedIDs.contains(id) }

    public mutating func toggle(_ id: String) {
        if selectedIDs.remove(id) == nil { selectedIDs.insert(id) }
    }

    /// The item ids a view offers for ticking, in its order: its item rows, never its collection rows.
    public static func selectableIDs(_ listing: [LibraryListing]) -> [String] {
        listing.compactMap { $0.itemRow?.id }
    }

    /// Every row of the current view is ticked, and there is at least one.
    public func isAllSelected(of visible: [String]) -> Bool {
        !visible.isEmpty && visible.allSatisfy(selectedIDs.contains)
    }

    /// Select All ticks every row the view shows; when they are all ticked already it reads Deselect All and clears.
    public mutating func toggleAll(_ visible: [String]) {
        if isAllSelected(of: visible) { selectedIDs.subtract(visible) } else { selectedIDs.formUnion(visible) }
    }

    public mutating func deselectAll() { selectedIDs.removeAll() }

    /// After the view changed (a filter, a search, an action that took rows away): only rows still shown stay ticked, so
    /// an action never touches something the listener can't see.
    public mutating func keepOnly(_ visible: [String]) {
        selectedIDs.formIntersection(visible)
    }

    /// The ticked ids in the view's order.
    public func ordered(in visible: [String]) -> [String] {
        visible.filter(selectedIDs.contains)
    }

    // MARK: Words

    /// The navigation title while selecting: "Select Items", "1 Selected", "6 Selected" (Mail, Photos).
    public var title: String { isEmpty ? "Select Items" : "\(count) Selected" }

    /// The leading toolbar button: "Select All", or "Deselect All" once everything shown is ticked.
    public func selectAllTitle(visible: [String]) -> String {
        isAllSelected(of: visible) ? "Deselect All" : "Select All"
    }

    /// What VoiceOver hears on a row while selecting; the tick's state is also given as the selected trait.
    public static func rowAccessibilityHint(isSelected: Bool) -> String {
        isSelected ? "Double-tap to deselect." : "Double-tap to select."
    }
}

/// What can be done to the ticked rows (#4720), and the words each says when it is done. Pure, so the toolbar, the
/// confirmation and the banner can't disagree with what was actually changed.
public enum LibraryBulkAction: String, CaseIterable, Identifiable, Sendable {
    case addToQueue
    case addToCollection
    case markFinished
    case markUnfinished
    case removeFromCollection
    case moveToRecentlyDeleted

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .addToQueue: return "Add to Queue"
        case .addToCollection: return "Add to Collection…"
        case .markFinished: return "Mark as Finished"
        case .markUnfinished: return "Mark as Unfinished"
        case .removeFromCollection: return "Remove from Collection"
        case .moveToRecentlyDeleted: return "Move to Recently Deleted"
        }
    }

    public var symbol: String {
        switch self {
        case .addToQueue: return "text.line.last.and.arrowtriangle.forward"
        case .addToCollection: return "rectangle.stack.badge.plus"
        case .markFinished: return "checkmark.circle"
        case .markUnfinished: return "circle"
        case .removeFromCollection: return "rectangle.stack.badge.minus"
        case .moveToRecentlyDeleted: return "trash"
        }
    }

    public var isDestructive: Bool { self == .moveToRecentlyDeleted }

    /// The actions the ticked rows allow, in toolbar and menu order. Nothing is offered for an empty selection. Mark as
    /// Finished is offered while any ticked row is unfinished; Mark as Unfinished while any was marked finished by hand
    /// (the only completion that can be taken back, `ManualItemCompletion`), so a mixed selection offers both. Remove
    /// from Collection only inside a collection.
    public static func available(for rows: [LibraryItemRow], insideCollection: Bool) -> [LibraryBulkAction] {
        guard !rows.isEmpty else { return [] }
        var actions: [LibraryBulkAction] = [.addToQueue, .addToCollection]
        if rows.contains(where: { !$0.isCompleted }) { actions.append(.markFinished) }
        if rows.contains(where: \.canMarkUnfinished) { actions.append(.markUnfinished) }
        if insideCollection { actions.append(.removeFromCollection) }
        actions.append(.moveToRecentlyDeleted)
        return actions
    }

    /// The rows this action would change, in the given order: Mark as Finished skips finished rows, Mark as Unfinished
    /// skips rows not marked by hand. The others change every row (queueing and collections skip duplicates themselves).
    public func rowsChanged(_ rows: [LibraryItemRow]) -> [LibraryItemRow] {
        switch self {
        case .markFinished: return rows.filter { !$0.isCompleted }
        case .markUnfinished: return rows.filter(\.canMarkUnfinished)
        default: return rows
        }
    }

    // MARK: Words

    static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    /// The confirmation before Move to Recently Deleted: a title and a destructive button, as Photos asks.
    public static func deleteConfirmation(count: Int) -> (title: String, button: String, message: String) {
        let what = count == 1 ? "1 Item" : "\(count) Items"
        return ("Move \(what) to Recently Deleted?", "Move \(what) to Recently Deleted",
                "You can restore them from Recently Deleted in Settings, along with their Margins.")
    }

    /// "Added 6 items to the queue." / "Added 4 items to the queue. 2 were already in it." /
    /// "All 3 items are already in the queue."
    public static func queuedBanner(added: Int, selected: Int) -> String {
        let already = selected - added
        guard added > 0 else { return selected == 1 ? "It's already in the queue." : "All \(selected) items are already in the queue." }
        let base = "Added \(items(added)) to the queue."
        guard already > 0 else { return base }
        return base + " \(already) \(already == 1 ? "was" : "were") already in it."
    }

    /// "Added 6 items to “FourSight”." / "Added 4 items to “FourSight”. 2 were already in it." / "Made “FourSight” with
    /// 6 items."
    public static func collectionBanner(added: Int, selected: Int, name: String, isNew: Bool) -> String {
        if isNew { return "Made “\(name)” with \(items(added))." }
        let already = selected - added
        guard added > 0 else {
            return selected == 1 ? "It's already in “\(name)”." : "All \(selected) items are already in “\(name)”."
        }
        let base = "Added \(items(added)) to “\(name)”."
        guard already > 0 else { return base }
        return base + " \(already) \(already == 1 ? "was" : "were") already in it."
    }

    /// The banner after the action changed `count` rows, for the actions whose wording needs only the count.
    public func banner(count: Int, collectionName: String? = nil) -> String {
        switch self {
        case .markFinished: return "Marked \(Self.items(count)) as finished."
        case .markUnfinished: return "Marked \(Self.items(count)) as unfinished."
        case .moveToRecentlyDeleted: return "Moved \(Self.items(count)) to Recently Deleted."
        case .removeFromCollection: return "Removed \(Self.items(count)) from “\(collectionName ?? "the collection")”."
        case .addToQueue: return Self.queuedBanner(added: count, selected: count)
        case .addToCollection: return Self.collectionBanner(added: count, selected: count, name: collectionName ?? "", isNew: false)
        }
    }
}

/// Adding many items to a collection and taking them out (#4720). Pure, like `ItemCollectionEditing`, whose name rules
/// it uses for a new collection named in the same flow.
public enum LibraryCollectionAdding {
    public struct Outcome: Equatable, Sendable {
        public var collection: ItemCollection
        /// How many of the items were not in it before.
        public var added: Int
        /// True when this flow made the collection.
        public var isNew: Bool
    }

    /// The items join at the end, in the order given; ones already in it keep their place.
    public static func adding(_ itemIDs: [String], to collection: ItemCollection, now: Date) -> Outcome {
        var edited = collection
        let before = Set(collection.itemIDs)
        let new = itemIDs.filter { !before.contains($0) }
        var seen = Set<String>()
        let unique = new.filter { seen.insert($0).inserted }
        edited.itemIDs.append(contentsOf: unique)
        if !unique.isEmpty { edited.updatedAt = now }
        return Outcome(collection: edited, added: unique.count, isNew: false)
    }

    /// A new collection, named in the same flow, holding the items in the order given. Nil when the name is empty or
    /// taken (`ItemCollectionEditing.isNameTaken` ignores case and accents).
    public static func creating(
        name: String, with itemIDs: [String], id: String, now: Date, in collections: [ItemCollection]
    ) -> Outcome? {
        guard let created = ItemCollectionEditing.creating(name: name, itemIDs: itemIDs, id: id, now: now, in: collections) else {
            return nil
        }
        return Outcome(collection: created, added: created.itemIDs.count, isNew: true)
    }

    /// The collection without `itemIDs`, and how many were taken out. The items and their Margins stay in the Library.
    public static func removing(_ itemIDs: [String], from collection: ItemCollection, now: Date) -> (collection: ItemCollection, removed: Int) {
        let gone = Set(itemIDs)
        var edited = collection
        edited.itemIDs.removeAll { gone.contains($0) }
        let removed = collection.itemIDs.count - edited.itemIDs.count
        if removed > 0 { edited.updatedAt = now }
        return (edited, removed)
    }
}
