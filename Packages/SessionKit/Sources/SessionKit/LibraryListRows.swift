import Foundation

/// One row of the Library list, identified by its item's id (#585).
public struct LibraryListEntry<Row: Identifiable>: Identifiable {
    public let row: Row
    /// The "Continue listening" row, drawn first and highlighted.
    public let isCurrent: Bool

    public var id: Row.ID { row.id }

    public init(row: Row, isCurrent: Bool) {
        self.row = row
        self.isCurrent = isCurrent
    }
}

/// #585: the Library list's rows in display order, the Continue row first.
///
/// The screen used to draw the Continue row in a slot of its own above a `ForEach` of the
/// other rows. Completing the top row kept that slot alive (its content switched to the
/// next item in progress) and deleted that item's row further down instead. The list then
/// animated the wrong row out while the swiped row stayed, and left a gap. Drawing every
/// row, the Continue row included, from these entries gives each row one identity, its
/// item's id, so completing the top row removes exactly that row and the rest move up.
public enum LibraryListRows {
    /// `visible` is the filtered, sorted list; `currentId` is the Continue item's id. The
    /// Continue item is drawn first only when it is visible under the current filters.
    public static func entries<Row: Identifiable>(
        visible rows: [Row],
        currentId: Row.ID?
    ) -> [LibraryListEntry<Row>] {
        guard let currentId, let current = rows.first(where: { $0.id == currentId }) else {
            return rows.map { LibraryListEntry(row: $0, isCurrent: false) }
        }
        return [LibraryListEntry(row: current, isCurrent: true)]
            + rows.filter { $0.id != currentId }.map { LibraryListEntry(row: $0, isCurrent: false) }
    }
}
