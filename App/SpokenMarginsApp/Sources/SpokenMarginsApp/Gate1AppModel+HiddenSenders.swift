import Foundation
import SessionKit

/// Hiding one sender's Margins or one Margin, and showing them again (#2846). The list is `hiddenSenders`; the loaders leave a hidden
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

    /// Hides one received Margin on this phone only. The Margin, if it is on its way to the listener's ears, stops first:
    /// an offer to play it, a reading of it, and any moment or review that has it sounding or still ahead.
    func hideMargin(layer: ImportedCommentaryLayer, margin: ImportedCommentaryInterjection) {
        if pendingImportedCommentary?.interjection.id == margin.id { dismissPendingImportedCommentary() }
        if playingImportedCommentary?.interjection.id == margin.id { stopImportedCommentaryPlayback(resumeSource: true) }
        // A moment or review that has this Margin sounding, as its next lead-in, or still ahead of it ends, so it can't
        // play later in the sequence. The source it paused comes back when a voice was sounding.
        let momentMarginId = SharedMarginReview.marginId(layerId: margin.layerId, interjectionId: margin.id)
        if let conductor = marginMomentConductor,
           ([conductor.sequence.target, conductor.sequence.playing].compactMap { $0 } + conductor.sequence.unplayed)
            .contains(where: { $0.marginId == momentMarginId }) {
            let voiceWasSounding = conductor.isPlayingVoice && !conductor.isVoicePaused
            endMarginMoment()
            if voiceWasSounding { resumePlayback(returningFromMargin: true) }
        }
        guard hiddenSenders.hideMargin(margin.id, senderLabel: layer.displayLabel, text: margin.approvedTranscript) else { return }
        reloadAfterSenderVisibilityChanged()
    }

    func showMargin(_ marginId: String) {
        hiddenSenders.unhideMargin(marginId)
        reloadAfterSenderVisibilityChanged()
    }

    private func reloadAfterSenderVisibilityChanged() {
        refreshSelectedItemInBackground()
        refreshMarginRowsInBackground()
        refreshLibraryRowsInBackground() // the Library row's shared count and New badge drop what is hidden (#3469)
    }
}
