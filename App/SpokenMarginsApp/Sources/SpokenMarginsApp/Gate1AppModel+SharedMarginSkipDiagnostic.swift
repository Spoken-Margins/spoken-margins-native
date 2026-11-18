import Foundation
import SessionKit

extension Gate1AppModel {
    /// A friend's Margin the source crossed while a card, a Margin voice, a review or a moment's voice held the offer
    /// slot is never offered and does not cross again (#4109). Say so in the export, so a run with the screen locked can
    /// tell a stuck slot from a Margin that was never placed. Reads the prompts only when the slot is busy and the
    /// selected item has friend Margins, and records only when one really crossed: a quiet tick costs nothing.
    func noteSharedMarginsCrossedWhileSlotBusy(previous: SessionSnapshot, current: SessionSnapshot) {
        guard current.itemId == selectedItem.id, !selectedItem.importedCommentaryLayers.isEmpty else { return }
        let crossed = SharedMarginOfferSkip.crossedCount(
            previous: previous, current: current, selectedItemID: selectedItem.id,
            prompts: importedCommentaryPrompts(includeAnnounced: false))
        guard crossed > 0 else { return }
        let slot = SharedMarginOfferSkip.Slot(
            pendingCard: pendingImportedCommentary != nil, playingVoice: playingImportedCommentary != nil,
            reviewRunning: marginMomentConductor?.sequence.isReview == true,
            momentVoice: marginMomentConductor?.isPlayingVoice == true)
        let fields = SharedMarginOfferSkip.eventFields(
            crossed: crossed, slot: slot, appState: Gate2AppState.isInBackground() ? "background" : "foreground",
            sourcePlaying: current.status.isPlaybackActive)
        diagnostics["lastSharedMarginSkipped"] = SharedMarginOfferSkip.diagnosticsLine(fields)
        recordDeveloperDiagnostic("margin.shared_offer_skipped", fields)
    }
}
