import Foundation

/// A list's place on screen, read before rows above it come or go (#1990): one row wholly in view, named by how far it
/// is from the end of the list, and how far its top edge sits below the list's offset.
///
/// Counting from the end is what makes the place hold. Rows added or removed above leave the count from the end alone,
/// so finding the row again never asks whether the list has taken the change yet. It finds the old row in the old list
/// and the same row in the new one. A count from the start needs to know that, and two lane runs failed on it: the list
/// had taken the new row before the keeper read its place, and the keeper then waited for a row that never came.
public struct ListPlace: Equatable, Sendable {
    public struct VisibleRow: Equatable, Sendable {
        /// The row's place in the list, counted across sections.
        public let index: Int
        public let top: Double
        public let bottom: Double

        public init(index: Int, top: Double, bottom: Double) {
            self.index = index
            self.top = top
            self.bottom = bottom
        }
    }

    /// The last row counts 1.
    public let rowsFromEnd: Int
    /// The row's top edge, measured from the list's offset.
    public let rowTop: Double

    /// The place to keep, or nil when there is none: at the very top of the list the listener should see a new row
    /// arrive, and a list with no row on screen has nothing to keep.
    ///
    /// The kept row is the last one wholly on screen, because it is the one furthest below the rows that change. If
    /// none is whole, the last one partly on screen.
    public static func reading(
        visibleRows: [VisibleRow],
        rowCount: Int,
        offset: Double,
        viewTop: Double,
        viewBottom: Double
    ) -> ListPlace? {
        guard viewTop > 1 else { return nil }
        let inList = visibleRows.filter { $0.index < rowCount }
        let whole = inList.filter { $0.top >= viewTop - 0.5 && $0.bottom <= viewBottom + 0.5 }
        guard let kept = (whole.isEmpty ? inList : whole).max(by: { $0.index < $1.index }) else { return nil }
        return ListPlace(rowsFromEnd: rowCount - kept.index, rowTop: kept.top - offset)
    }

    /// The kept row's index in a list of `rowCount` rows, or nil if the list is now too short to hold it.
    public func rowIndex(inListOf rowCount: Int) -> Int? {
        let index = rowCount - rowsFromEnd
        return index >= 0 ? index : nil
    }

    /// The offset that puts the kept row back at its distance, given where the row's top edge is in the list now. The
    /// list can't scroll past its ends, so the result stays between them.
    public func offset(keepingRowAt rowTopInList: Double, lowest: Double, highest: Double) -> Double {
        min(max(rowTopInList - rowTop, lowest), max(lowest, highest))
    }
}
