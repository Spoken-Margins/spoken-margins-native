import Foundation
import SessionKit
import SessionKitPersistence

/// Renaming a spoken note (#3663). The rules (what a title may be, what a blank one means, that only the title changes)
/// are `SpokenNoteTitle`'s and the store's; this hands the store call off the main thread and then makes every screen show
/// the new name: the Library row, the Margins that name their source, and Now and the Lock Screen when the note is open.
extension Gate1AppModel {
    /// Renames the note's Library item. Returns the title the note has now, or nil when it could not be renamed (the note is
    /// gone or in Recently Deleted), in which case a plain line says so. A blank `input` puts the made-up title back.
    @discardableResult
    func renameSpokenNote(itemId: String, to input: String) async -> String? {
        guard let store else {
            reportFailure("The Library isn't ready yet. Try again in a moment.")
            return nil
        }
        let title: String?
        do {
            title = try await Task.detached(priority: .userInitiated) {
                try store.renameSpokenNote(itemId: itemId, to: input)
            }.value
        } catch {
            reportFailure(error, context: "Rename failed", itemId: itemId)
            return nil
        }
        guard let title else {
            reportFailure("This note can't be renamed. It may have been moved to Recently Deleted.", itemId: itemId)
            return nil
        }
        // What is on screen follows at once; the background reads then confirm it from the database.
        if let engine, engine.currentSession?.itemId == itemId || snapshot.itemId == itemId {
            snapshot = engine.applyItemTitle(itemId: itemId, title: title)
        }
        // The item screens and Now read the title off the item detail, not the playback snapshot.
        if var detail = activePlaybackDetail, detail.id == itemId {
            detail.title = title
            activePlaybackDetail = detail
        }
        if activeItemId == itemId { refreshSelectedItemInBackground() }
        refreshLibraryRowsInBackground(mustPublish: true)
        refreshMarginRowsInBackground(forItem: itemId)
        return title
    }
}
