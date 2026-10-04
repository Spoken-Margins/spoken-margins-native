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

    /// Starts the added item through the normal start path, which opens the playback screen. If
    /// something started in the meantime, the tap does nothing: imports never replace what's playing.
    func playNowAfterAdding(itemId: String) {
        guard nowPlayingIsEmpty else { return }
        startItem(id: itemId)
    }
}
