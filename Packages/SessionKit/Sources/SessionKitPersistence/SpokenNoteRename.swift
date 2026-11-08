import Foundation
import SessionKit

/// The database renames a spoken note's Library item (#3663).
extension SQLiteSessionStore {
    /// Renames a note's row and returns the title the row has now (the same one when it already had it), or nil when the row
    /// can't be renamed: missing, in Recently Deleted, or not a spoken note. Only the title changes
    /// (`SpokenNoteTitle.renamed`): the audio and transcript sit beside the row, and the Margins hang on its id.
    /// Call it off the main thread. The read and the write are one hold of the connection lock, so a transcript that lands
    /// in between (`SpokenNoteItemWriting.write`) can't be written over by the row read before it.
    public func renameSpokenNote(itemId: String, to input: String) throws -> String? {
        try withConnectionLock {
            guard let stored = try? loadItem(id: itemId), SpokenNoteItem.isSpokenNote(mediaType: stored.mediaType),
                  stored.deletedAt == nil else { return nil }
            guard let renamed = SpokenNoteTitle.renamed(stored, to: input) else { return stored.title }
            try saveItem(renamed)
            return renamed.title
        }
    }
}
