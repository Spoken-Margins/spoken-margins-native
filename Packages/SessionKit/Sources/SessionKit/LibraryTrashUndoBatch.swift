import Foundation

/// What one Undo after Move to Recently Deleted brings back (#4720). A row's own delete moves one; Select's bulk delete
/// moves many, and its single Undo restores every one that was moved, never one that failed to move.
public struct LibraryTrashUndoBatch: Equatable, Sendable {
    /// The moved items, in the order they were moved.
    public let itemIDs: [String]
    /// Their titles, in the same order.
    public let titles: [String]

    /// Nil when nothing was moved, so no Undo is offered for a delete that did nothing.
    public init?(moved: [(id: String, title: String)]) {
        var seen = Set<String>()
        let unique = moved.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return nil }
        itemIDs = unique.map(\.id)
        titles = unique.map(\.title)
    }

    public var count: Int { itemIDs.count }

    public func contains(_ itemID: String) -> Bool { itemIDs.contains(itemID) }

    /// What the banner names after "Moved …": the title for one, "6 items" for several.
    public var name: String {
        count == 1 ? titles[0] : LibraryBulkAction.items(count)
    }

    /// The banner after Undo: "Restored <title>." for one, "Restored 6 items." for several. When only some came back,
    /// the count is of those, so the banner never claims what didn't happen.
    public func restoredBanner(restoredIDs: [String]) -> String {
        let restored = itemIDs.filter(restoredIDs.contains)
        if restored.count == 1, let index = itemIDs.firstIndex(of: restored[0]) { return "Restored \(titles[index])." }
        return "Restored \(LibraryBulkAction.items(restored.count))."
    }
}
