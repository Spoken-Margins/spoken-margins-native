import Foundation
import SessionKit

/// #477: Dismiss in Following is confirmed on the app's shared top banner, with an Undo button, as
/// Mark Complete is (#1149). A full left swipe dismisses at once, so a stray one can be taken back.
extension Gate1AppModel {
    func dismissFollowedSourceEntry(id: String) {
        guard let coordinator = followedSourceCoordinator else { return }
        let title = followedSourceEntries.first { $0.id == id }?.title ?? ""
        listeningSignals.dismiss(entryId: id)
        Task { [weak self] in
            let previous = try? await coordinator.dismissEntry(id: id)
            await self?.performFollowedSourceRefresh(force: false)
            guard let previous else { return }
            self?.presentDismissUndo(title: title) { [weak self] in
                self?.undoDismissedFollowedSourceEntry(id: id, restoring: previous)
            }
        }
    }

    /// Puts the entry back in the state it had, through the existing entry-state path: no new field.
    func undoDismissedFollowedSourceEntry(id: String, restoring previous: FeedEntryState) {
        guard let coordinator = followedSourceCoordinator else { return }
        Task { [weak self] in
            try? await coordinator.undoDismissEntry(id: id, restoring: previous)
            await self?.performFollowedSourceRefresh(force: false)
        }
    }

    /// A Quick Folder file's dismissal lives in `UserDefaults`; Undo removes it from there.
    func dismissQuickAccessFileWithUndo(_ file: QuickAccessFile) {
        dismissQuickAccessFile(file)
        presentDismissUndo(title: file.name) { [weak self] in self?.restoreQuickAccessFile(file) }
    }

    private func presentDismissUndo(title: String, undo: @escaping @MainActor () -> Void) {
        // A later dismissal replaces this banner, so the Undo on screen is always the newest one.
        let action = UserFeedbackEvent.Action(
            title: FollowingDismissMessages.undoTitle,
            accessibilityLabel: FollowingDismissMessages.undoAccessibilityLabel(title: title),
            identifier: "following.undo.button",
            perform: undo
        )
        presentFeedback(UserFeedbackEvent(kind: .success, message: FollowingDismissMessages.dismissed(title: title), action: action))
    }
}
