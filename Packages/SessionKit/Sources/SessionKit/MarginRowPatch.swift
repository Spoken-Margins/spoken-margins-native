import Foundation

/// Changing the Margins list for one item without rebuilding it for every item (#2505).
///
/// Saving, undoing, trashing or restoring touches one item's Margins. The list keeps every other item's rows as
/// they are and swaps in that item's rows, in the order a full `MarginCollection.build` gives.
extension MarginCollection {
    /// Newest session first, then newest Margin, then identity: the order of the Margins tab.
    public static func ordered(_ rows: [PrivateEntry]) -> [PrivateEntry] {
        rows.sorted { lhs, rhs in
            let leftSessionDate = lhs.sessionDate ?? .distantPast
            let rightSessionDate = rhs.sessionDate ?? .distantPast
            if leftSessionDate != rightSessionDate { return leftSessionDate > rightSessionDate }
            if lhs.interjection.createdAt != rhs.interjection.createdAt {
                return lhs.interjection.createdAt > rhs.interjection.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    /// `existing` with every row of `itemId` replaced by `fresh` (empty `fresh` drops them, as a trashed item does).
    public static func replacingItem(_ itemId: String, in existing: [PrivateEntry], with fresh: [PrivateEntry]) -> [PrivateEntry] {
        ordered(existing.filter { $0.interjection.itemId != itemId } + fresh)
    }

    /// The shared (imported) rows, with `itemId`'s replaced by `fresh`, newest first.
    public static func replacingItem(_ itemId: String, in existing: [SharedEntry], with fresh: [SharedEntry]) -> [SharedEntry] {
        (existing.filter { $0.layer.itemId != itemId } + fresh).sorted { $0.interjection.createdAt > $1.interjection.createdAt }
    }
}
