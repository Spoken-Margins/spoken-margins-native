import Foundation
import SessionKit

/// The 20 s reply window after a friend's voice that a Margin moment or review plays (#5238). The owner's rule
/// (2026-11-09) holds on every player: only the shared-Margin player fed the reply memory before, so a Margin made
/// right after a friend's reply in a catch-up run was saved as an independent Margin.
extension Gate1AppModel {
    /// A moment's voice started. A friend's opens the window; the listener's own ends it, so a Margin recorded over the
    /// listener's own voice never answers the friend's Margin before it.
    func openMomentReplyWindow(marginId: String, itemId: String) {
        guard let draft = MomentReplyWindow.draft(forMarginId: marginId, rows: sharedMarginRows) else {
            marginCapture.forgetSharedReply()
            if marginId.hasPrefix("shared::") { diagnostics["marginMoment.replyWindow"] = "no_row" } // rows not caught up with an import
            return
        }
        marginCapture.sharedMarginBegan(draft, itemId: itemId)
    }

    /// The voice stopped: the 20 s start now.
    func closeMomentReplyWindow() {
        marginCapture.sharedMarginEnded()
    }
}
