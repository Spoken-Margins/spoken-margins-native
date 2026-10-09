import Foundation
import SessionKit

/// #1149: marking an item complete is confirmed on the app's shared top banner, with an Undo button.
/// It used to be a row inside the Library list, which pushed every row down while it showed.
extension Gate1AppModel {
    func presentCompletionUndo(itemId: String, title: String, markedAt: Date) {
        // The button carries the completion it undoes. A later completion replaces this banner, so the
        // Undo on screen is always the newest one; an older completion is undone from its row (#273).
        let undo = UserFeedbackEvent.Action(
            title: ManualCompletionMessages.undoTitle,
            accessibilityLabel: ManualCompletionMessages.undoAccessibilityLabel(title: title),
            identifier: "completion.undo.button",
            perform: { [weak self] in self?.undoMarkedCompletion(itemId: itemId, markedAt: markedAt) }
        )
        // Marking complete never wrote a status or cleared the recent-failure diagnostic, and still doesn't.
        presentFeedback(UserFeedbackEvent(kind: .success, message: ManualCompletionMessages.completed(title: title), action: undo))
    }
}
