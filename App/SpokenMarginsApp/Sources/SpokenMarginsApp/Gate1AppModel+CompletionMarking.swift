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
            refreshLibraryRowsInBackground(mustPublish: true)
            try reloadSelectedItemAfterCompletionChange(id: id, store: store)
            presentCompletionUndo(itemId: id, title: item.title, markedAt: item.sourceCompletedAt ?? Date())
            saveCompletedSpokenNoteToExportFolder(item) // A spoken note goes to the export folder (#3661).
        } catch {
            reportFailure(error, context: "Mark complete failed")
        }
    }

    /// The second mark complete (#4289): a finished item with a friend's new Margins leaves the Library's Unfinished view
    /// once the listener says they're done with those Margins. Only the heard time changes (what playing a Margin
    /// records); nothing is removed, and the item's own completion is untouched.
    func markItemMarginsHeard(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_item_margins_heard") else { return }
        do {
            let store = try requireStore()
            guard try ItemMarginsHeard.markHeard(itemId: id, hiding: hiddenSenders.current, in: store) > 0 else { return }
            refreshLibraryRowsInBackground(mustPublish: true)
            refreshMarginRowsInBackground(forItem: id)
            try reloadSelectedItemAfterCompletionChange(id: id, store: store)
            let title = libraryItems.first { $0.id == id }?.title ?? selectedItem.title
            reportConfirmation(ManualCompletionMessages.marginsHeard(title: title))
        } catch {
            reportFailure(error, context: "Mark Margins heard failed")
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
            refreshLibraryRowsInBackground(mustPublish: true)
            try reloadSelectedItemAfterCompletionChange(id: id, store: store)
            reportConfirmation(markedAt == nil
                ? ManualCompletionMessages.unfinished(title: item.title)
                : ManualCompletionMessages.undone(title: item.title))
        } catch { reportFailure(error, context: "Mark unfinished failed") }
    }
}
