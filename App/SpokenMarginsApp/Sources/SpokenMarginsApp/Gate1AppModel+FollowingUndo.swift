import Foundation
import SessionKit

/// #477: Dismiss in Following is confirmed on the app's shared top banner, with an Undo button, as
/// Mark Complete is (#1149). A full left swipe dismisses at once, so a stray one can be taken back.
/// #4285: on a followed show's episode the action is "Not for me". It also writes a mark the phone keeps, so the
/// episode stays out of New after the show is unfollowed and followed again; Undo takes the mark off first.
extension Gate1AppModel {
    /// Takes the row's own entry, not a lookup in `followedSourceEntries`: a show's Up next card can draw an episode that
    /// list doesn't hold, and the mark needs the entry's GUID and addresses.
    func dismissFollowedSourceEntry(_ entry: FeedEntry) {
        guard let coordinator = followedSourceCoordinator else { return }
        let id = entry.id
        let title = entry.title
        Task { [weak self] in
            guard let previous = try? await coordinator.dismissEntry(id: id) else { return }
            self?.listeningSignals.dismiss(entryId: id)
            // The banner comes first: the refresh below can wait on the network, past the Undo window.
            self?.presentNotForMeUndo(title: title) { [weak self] in
                self?.undoDismissedFollowedSourceEntry(id: id, restoring: previous, unmarking: entry)
            }
            // The mark is written before the refresh, which is the first thing that could save the episode again.
            _ = await self?.markNotForMe(entry)
            await self?.reloadFollowedSourceEntries()
            await self?.performFollowedSourceRefresh(force: false, trigger: .localChange)
        }
    }

    /// Puts the entry back in the state it had, through the existing entry-state path: no new field. The Not for me
    /// mark goes first, so a refresh between the two can't dismiss the entry again.
    func undoDismissedFollowedSourceEntry(id: String, restoring previous: FeedEntryState, unmarking entry: FeedEntry? = nil) {
        guard let coordinator = followedSourceCoordinator else { return }
        Task { [weak self] in
            if let entry { await self?.unmarkNotForMe(entry) }
            try? await coordinator.undoDismissEntry(id: id, restoring: previous)
            await self?.reloadFollowedSourceEntries()
            await self?.performFollowedSourceRefresh(force: false, trigger: .undo)
        }
    }

    /// "Clear" on the New list (#1589): dismisses every followed entry listed, with one Undo. It
    /// records no listening signal: clearing a pile is not a verdict on each entry.
    func clearFollowedSourceEntries(ids: [String]) {
        guard let coordinator = followedSourceCoordinator, !ids.isEmpty else { return }
        Task { [weak self] in
            guard let previous = try? await coordinator.dismissEntries(ids: ids), !previous.isEmpty else { return }
            let count = previous.count
            let action = UserFeedbackEvent.Action(
                title: FollowingDismissMessages.undoTitle,
                accessibilityLabel: FollowingDismissMessages.clearUndoAccessibilityLabel(count: count),
                identifier: "following.undo.button",
                perform: { [weak self] in self?.undoClearedFollowedSourceEntries(previous) }
            )
            self?.presentFeedback(UserFeedbackEvent(kind: .success, message: FollowingDismissMessages.cleared(count: count), action: action))
            await self?.reloadFollowedSourceEntries()
            await self?.performFollowedSourceRefresh(force: false, trigger: .localChange)
        }
    }

    func undoClearedFollowedSourceEntries(_ previous: [String: FeedEntryState]) {
        guard let coordinator = followedSourceCoordinator else { return }
        Task { [weak self] in
            try? await coordinator.undoDismissEntries(restoring: previous)
            await self?.reloadFollowedSourceEntries()
            await self?.performFollowedSourceRefresh(force: false, trigger: .undo)
        }
    }

    /// A Quick Folder file's dismissal lives in `UserDefaults`; Undo removes it from there.
    func dismissQuickAccessFileWithUndo(_ file: QuickAccessFile) {
        dismissQuickAccessFile(file)
        presentDismissUndo(title: file.name) { [weak self] in self?.restoreQuickAccessFile(file) }
    }

    /// Dismiss on Following's "Suggested by your AI" row (#4683): every pending suggestion goes, with one Undo that puts
    /// them back whole (and keeps any that arrived in between).
    func dismissAIFollowSuggestionsWithUndo() {
        let suggestions = aiFollowSuggestionsModel
        let previous = suggestions.dismissAll()
        guard !previous.isEmpty else { return }
        presentDismissUndo(title: AIFollowSuggestionsRow.title) { suggestions.restore(previous) }
    }

    /// Following's "Suggested by your AI" row was tapped (#4683): its shows open in the follow preview, titled for the AI.
    /// Nothing is followed until the listener taps Follow there.
    func openAIFollowSuggestions(_ row: AIFollowSuggestionsRow, in drawer: CatalogDrawerModel) {
        if drawer.shortcutImport?.isFollowing == true {
            reportWarning(AIFollowSuggestionsRow.stillFollowingMessage)
            return
        }
        drawer.openShortcutImport(feedLinks: row.feedLinks, origin: .assistant)
    }

    private func presentNotForMeUndo(title: String, undo: @escaping @MainActor () -> Void) {
        let action = UserFeedbackEvent.Action(
            title: FollowingDismissMessages.undoTitle,
            accessibilityLabel: FollowingDismissMessages.notForMeUndoAccessibilityLabel(title: title),
            identifier: "following.undo.button",
            perform: undo
        )
        presentFeedback(UserFeedbackEvent(kind: .success, message: FollowingDismissMessages.notForMe(title: title), action: action))
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
