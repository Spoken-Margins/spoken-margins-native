import Foundation
import SessionKit

/// Replying to a friend's shared Margin (#473): the Reply action starts the normal recorder, or the written
/// Margin screen, at the Margin's position in the listener's copy, and the saved Margin carries the link to its
/// parent. The link rides the capture request (see `MarginCaptureRequest.replyTo`), so every way of finishing
/// the recording keeps it.
extension Gate1AppModel {
    /// The shared Margin the recording on screen answers, for the recording screen to name.
    var pendingMarginReply: MarginReplyDraft? { marginCapture.pendingReply }

    /// Reply to `row` by voice, or in writing. The source moves to the Margin's position first, so the reply is
    /// anchored to the moment it answers.
    func replyToSharedMargin(_ row: SharedMarginRow, inWriting: Bool) {
        guard !rejectNavigationOrSessionMutationWhileRecording("reply_to_shared_margin") else { return }
        guard let itemID = row.layer.itemId else {
            reportFailure("The source for this shared Margin isn't in your Library.")
            return
        }
        guard let position = SharedMarginPlaybackPosition(row.interjection) else {
            reportFailure("This shared Margin has no position in the episode, so a reply can't be placed.")
            return
        }
        endMarginMoment()
        if snapshot.itemId != itemID || !hasActiveSession { startItem(id: itemID) }
        guard snapshot.itemId == itemID, seekMedia(toMediaTimeMs: position.mediaTimeMs) else { return }
        screen = .playback
        let reply = MarginReplyDraft(parent: row.interjection, in: row.layer)
        if inWriting {
            beginWrittenMargin(answering: reply)
            return
        }
        marginCapture.setPendingReply(reply)
        beginInterjection()
        // The tap was refused (a save under way, Skim): nothing will clear the link, so it goes now.
        if !isRequestingRecordingPermission && !snapshot.isRecording { marginCapture.setPendingReply(nil) }
    }

    /// Every active Margin of `itemId` in thread order, for the lists and the Timeline.
    func marginThreadRows(itemId: String) -> [MarginThreadPresentation.Row] {
        MarginThreadPresentation.rows(
            itemId: itemId,
            localMargins: marginRows.map(\.interjection),
            layers: sharedMarginRows.map(\.layer),
            importedMargins: sharedMarginRows.map(\.interjection)
        )
    }

    /// The Margin a reply answers, when it is in this Library.
    func marginParentContext(of reference: MarginReference, itemId: String) -> MarginThreadPresentation.ParentContext? {
        MarginThreadPresentation.parentContext(
            of: reference,
            itemId: itemId,
            localMargins: marginRows.map(\.interjection),
            layers: sharedMarginRows.map(\.layer),
            importedMargins: sharedMarginRows.map(\.interjection)
        )
    }

    /// Plays the Margin a reply answers, with the same lead-in as tapping it anywhere else.
    func playMarginParent(_ context: MarginThreadPresentation.ParentContext) {
        switch context.parent {
        case .local(let id):
            if let row = marginRows.first(where: { $0.interjection.id == id }) { _ = playMarginMoment(row) }
        case .imported(let id):
            if let row = sharedMarginRows.first(where: { $0.interjection.id == id }) { playSharedMarginMoment(row) }
        }
    }
}
