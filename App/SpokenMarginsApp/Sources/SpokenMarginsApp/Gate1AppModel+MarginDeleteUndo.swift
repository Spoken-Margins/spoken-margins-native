import Foundation
import SessionKit

/// Undo for "Deleted Margin" (#1981). Deleting only hides the Margin; its recording and place stay, so Undo is
/// the same banner button a Following dismissal has, and a listener using VoiceOver keeps it until they act (#1927).
extension Gate1AppModel {
    func presentMarginDeleteUndo(_ interjection: Interjection) {
        presentFeedback(UserFeedbackEvent(
            kind: .success,
            message: "Deleted Margin.",
            action: UserFeedbackEvent.Action(
                title: "Undo",
                accessibilityLabel: "Undo deleting this Margin",
                identifier: "margin.deleteUndo.button",
                perform: { [weak self] in self?.restoreDeletedMargin(interjection) }
            )
        ))
    }

    func restoreDeletedMargin(_ interjection: Interjection) {
        // The item may have been moved to Recently Deleted or removed since; its Margins go with it.
        guard let store, let item = try? store.loadItem(id: interjection.itemId), item.deletedAt == nil else {
            reportFailure("Can't restore this Margin: its item was deleted.")
            return
        }
        run { engine in
            snapshot = try engine.restoreInterjection(interjectionId: interjection.id, sessionId: interjection.sessionId)
            refreshSelectedItem()
            reportConfirmation("Margin restored.")
        }
        // A podcast Margin deleted while its context was pending would otherwise stay pending.
        retrySourceWindowContexts(itemId: interjection.itemId)
        refreshMarginRows()
    }
}
