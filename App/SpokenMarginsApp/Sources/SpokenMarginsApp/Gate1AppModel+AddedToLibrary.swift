import Foundation
import SessionKit

/// #784: "Added <title> to Library." gets a Play now button when nothing is in Now Playing.
/// Nothing plays by itself: only the tap starts the item, and only if Now Playing is still empty then.
extension Gate1AppModel {
    var nowPlayingIsEmpty: Bool {
        AddedToLibraryConfirmation.nowPlayingIsEmpty(sessionId: snapshot.sessionId, phase: snapshot.phase)
    }

    func reportAddedToLibrary(title: String, itemId: String) {
        let confirmation = AddedToLibraryConfirmation(title: title, nowPlayingIsEmpty: nowPlayingIsEmpty)
        let playNow = confirmation.offersPlayNow ? UserFeedbackEvent.Action(
            title: "Play now",
            accessibilityLabel: AddedToLibraryConfirmation.playNowAccessibilityLabel(title: title),
            identifier: "app.feedback.playNow",
            perform: { [weak self] in self?.playNowAfterAdding(itemId: itemId) }
        ) : nil
        reportConfirmation(confirmation.message, action: playNow)
    }

    /// #828: Safari shares imported at launch or foreground. One item gets the usual confirmation with Play now;
    /// several share one message with no button. Nothing plays by itself.
    func reportPendingHandoffsAdded(itemIds: [String]) {
        guard let first = itemIds.first else { return }
        if itemIds.count == 1 {
            let title = libraryItems.first { $0.id == first }?.title ?? "Shared item"
            reportAddedToLibrary(title: title, itemId: first)
        } else {
            reportConfirmation(AddedToLibraryConfirmation.message(addedCount: itemIds.count, nowPlayingIsEmpty: nowPlayingIsEmpty))
        }
    }

    /// Starts the added item through the normal start path, which opens the playback screen. If
    /// something started in the meantime, the tap does nothing: imports never replace what's playing.
    func playNowAfterAdding(itemId: String) {
        guard nowPlayingIsEmpty else { return }
        startItem(id: itemId)
    }
}
