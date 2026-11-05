import Foundation
import SessionKit

/// The database is a spoken note's Library item writer (#3108). The note's coordinator calls it on its own executor,
/// never the main thread, so the app's main-thread model passes the store along and makes no store call of its own.
/// It reads the stored row and changes only its text (`SpokenNoteItemMerge`), so a row the listener trashed, renamed
/// or emptied from the trash while a transcript ran is not brought back or overwritten.
extension SQLiteSessionStore: SpokenNoteItemWriting {
    public func write(_ item: Item, isFirstSave: Bool) throws {
        let stored = try? loadItem(id: item.id)
        guard let row = SpokenNoteItemMerge.rowToSave(stored: stored, incoming: item, isFirstSave: isFirstSave) else { return }
        try saveItem(row)
    }
}
