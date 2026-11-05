import Foundation
import SessionKit

/// Hiding one sender's Margins, and showing them again (#2846). The list is `hiddenSenders`; the loaders leave a hidden
/// sender's layers out of every screen. This file only changes the list and reloads what is on screen.
extension Gate1AppModel {
    /// Hides every Margin from the sender behind `senderId`, on this phone only. A Margin from them that is playing
    /// stops first, and so does an offer to play one, so nothing hidden is still heard.
    func hideSender(_ senderId: String?, label: String?) {
        guard SenderID.valid(senderId) != nil else { return }
        if pendingImportedCommentary?.layer.senderId == senderId { dismissPendingImportedCommentary() }
        if playingImportedCommentary?.layer.senderId == senderId { stopImportedCommentaryPlayback(resumeSource: true) }
        guard hiddenSenders.hide(senderId, displayLabel: label) else { return }
        reloadAfterSenderVisibilityChanged()
    }

    func showSender(_ senderId: String) {
        hiddenSenders.unhide(senderId)
        reloadAfterSenderVisibilityChanged()
    }

    private func reloadAfterSenderVisibilityChanged() {
        refreshSelectedItem()
        refreshMarginRowsInBackground()
    }
}
