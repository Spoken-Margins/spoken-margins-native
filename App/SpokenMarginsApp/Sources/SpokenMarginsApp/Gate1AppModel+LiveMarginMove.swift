import Foundation
import SessionKit

/// What the model does when live-session Margins move onto an item (#4233): it starts the jobs a new Margin gets, refreshes
/// the lists and shows the banner. The move's rules and writes are `LiveMarginMove`'s and its order is `LiveMarginMoving`'s;
/// nothing about moving is decided here.
extension Gate1AppModel {
    /// After the item side is written: a spoken Margin with no words yet gets the item's transcription (with no fingerprint,
    /// since its recording wasn't made while the item played), a placed Margin with words gets its context job, and the
    /// item's lists are read again.
    func liveMarginsMoved(_ moved: [Interjection]) {
        hangTelemetry.labels.scoped("liveMarginMove") {
            for margin in moved {
                if margin.audioPath != nil, margin.transcriptionStatus == "pending" {
                    scheduleTranscription(for: margin, capturesAnchorEvidence: false)
                } else if margin.hasPlace {
                    _ = scheduleSourceWindowContextIfNeeded(for: margin)
                }
            }
            if let itemId = moved.first?.itemId { liveMarginsTakenBack(itemId: itemId) }
        }
    }

    /// The item's Margin lists, read again after a move or its Undo.
    func liveMarginsTakenBack(itemId: String) {
        refreshMarginRowsInBackground(forItem: itemId)
        if activeItemId == itemId { refreshSelectedItemInBackground() }
    }

    /// "Moved 3 Margins to “Title”." with Undo, as long as the Margin-delete Undo banner stays.
    func presentLiveMarginMoveUndo(count: Int, title: String, undo: @escaping @MainActor () -> Void) {
        presentFeedback(UserFeedbackEvent(
            kind: .success,
            message: LiveMarginMove.Wording.moved(count: count, title: title),
            action: UserFeedbackEvent.Action(
                title: "Undo",
                accessibilityLabel: "Undo moving these Margins",
                identifier: "liveSession.move.undo.button",
                perform: undo
            )
        ))
    }
}
