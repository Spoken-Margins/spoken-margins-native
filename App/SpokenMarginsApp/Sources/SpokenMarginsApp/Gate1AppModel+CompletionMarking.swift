import Foundation
import SessionKit
import SessionKitPersistence

/// Library completion marking. Moved out of `Gate1AppModel.swift` unchanged (#1007).
extension Gate1AppModel {
    func markItemCompleted(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_item_completed") else { return }
        do {
            let store = try requireStore()
            // Completion is an item-level fact, not fabricated listening history.
            guard let item = try ManualItemCompletion.markComplete(itemId: id, in: store) else { return }
            listeningSignals.finish(itemId: id)
            marginOutput.noteCompletion(ofItem: id) // One note per item mode (#587).
            refreshLibraryRowsInBackground()
            try reloadSelectedItemAfterCompletionChange(id: id, store: store)
            presentCompletionUndo(itemId: id, title: item.title, markedAt: item.sourceCompletedAt ?? Date())
        } catch {
            reportFailure(error, context: "Mark complete failed")
        }
    }

    /// The open item screen shows the completion state too. It reloads off the main thread when it is the active item;
    /// a selection that isn't the active item (rare) keeps the direct read (#2505).
    private func reloadSelectedItemAfterCompletionChange(id: String, store: SQLiteSessionStore) throws {
        guard selectedItem.id == id else { return }
        if activeItemId == id {
            refreshSelectedItemInBackground()
        } else {
            selectedItem = try loadItemDetail(id: id, store: store)
        }
    }

    func undoMarkedCompletion(itemId: String, markedAt: Date) {
        clearMarkedCompletion(id: itemId, markedAt: markedAt)
    }

    /// Any time after the undo banner is gone (#273). Only a completion set by hand.
    func markItemUnfinished(id: String) { clearMarkedCompletion(id: id, markedAt: nil) }

    private func clearMarkedCompletion(id: String, markedAt: Date?) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_item_unfinished") else { return }
        do {
            let store = try requireStore()
            // Never a later completion, and never natural session completion.
            guard let item = try ManualItemCompletion.markUnfinished(itemId: id, markedAt: markedAt, in: store) else { return }
            refreshLibraryRowsInBackground()
            try reloadSelectedItemAfterCompletionChange(id: id, store: store)
            reportConfirmation(markedAt == nil
                ? ManualCompletionMessages.unfinished(title: item.title)
                : ManualCompletionMessages.undone(title: item.title))
        } catch { reportFailure(error, context: "Mark unfinished failed") }
    }
}
