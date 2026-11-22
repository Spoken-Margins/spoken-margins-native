import Foundation
import SessionKit

/// The Undo banner after Move to Recently Deleted: one item from its row, or every item a Select delete moved (#4720).
struct TrashUndoState: Identifiable, Equatable {
    let id = UUID()
    let batch: LibraryTrashUndoBatch

    init(batch: LibraryTrashUndoBatch) {
        self.batch = batch
    }

    init(itemId: String, title: String) {
        // A batch of one is never nil.
        batch = LibraryTrashUndoBatch(moved: [(itemId, title)])!
    }

    /// The first moved item; the only one after a row's own delete.
    var itemId: String { batch.itemIDs[0] }
    var itemIds: [String] { batch.itemIDs }
    /// What "Moved … to Recently Deleted" names: the title, or "6 items".
    var title: String { batch.name }
}
