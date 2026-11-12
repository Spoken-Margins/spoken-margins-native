import Foundation
import SessionKit
import SessionKitPersistence

/// The listener's say on whether a friend's written Margin is read aloud (owner, 2026-11-05, #3427). The sender may have
/// asked for it not to be (a key in the packet); the listener's choice beats that, either way, and stays on this phone.
/// What follows from the choice (a card, Skim's stops, a Play button) is `ImportedCommentaryInterjection.readsAloud`
/// through `SharedMarginAudio.canOffer`; this file only records the choice and brings the screens up to date. It sits
/// in its own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// Turns reading aloud on or off for `margin`. A reading that is on the screen or sounding for it stops first when
    /// the choice is "off", so nothing the listener just turned off is still heard. The screens show the choice at once;
    /// the row is written off the main thread, and a failed write is read back so the screen never keeps a choice the
    /// store doesn't have (as `markSharedMarginHeard` does).
    func setSharedMarginReadAloud(_ margin: ImportedCommentaryInterjection, readAloud: Bool) {
        guard margin.isWritten, margin.readAloudChoice != readAloud else { return }
        var edited = margin
        edited.listenerReadAloud = readAloud
        let chosen = edited
        if !readAloud {
            if pendingImportedCommentary?.interjection.id == margin.id { dismissPendingImportedCommentary() }
            if playingImportedCommentary?.interjection.id == margin.id { stopImportedCommentaryPlayback(resumeSource: true) }
            // A reading sounding through a moment (Play this moment, Skim, a review) stops too; the source it paused comes back.
            if marginMomentConductor?.sequence.playing?.marginId == SharedMarginReview.marginId(layerId: margin.layerId, interjectionId: margin.id),
               endMarginMomentVoiceIfPlaying() {
                resumePlayback(returningFromMargin: true)
            }
        }
        showSharedMarginReadAloud(chosen)
        // Turning reading off for a Margin never played leaves its words as the only way to meet it, so opening the
        // sheet to turn it off counts as meeting it: it stops showing as new.
        if !readAloud, margin.isNewToListener { markSharedMarginHeard(chosen) }
        guard let store else { return }
        let (layerId, marginId) = (margin.layerId, margin.id)
        let reader = StoreReader(store)
        // Off the main thread, with nothing of the model captured but a weak reference to report a failure.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Only the choice is written, onto the stored record, so a placement pass that landed since the screen's
                // copy was read is not undone by this save.
                try await reader.read(priority: .userInitiated) { store in
                    var stored = try store.loadImportedCommentaryInterjections(layerId: layerId).first { $0.id == marginId } ?? chosen
                    stored.listenerReadAloud = readAloud
                    try store.saveImportedCommentaryInterjection(stored)
                }
            } catch {
                await self?.sharedMarginReadAloudFailed(marginId, error)
            }
        }
    }

    private func sharedMarginReadAloudFailed(_ marginId: String, _ error: Error) {
        diagnostics["sharedMarginReadAloud:\(marginId)"] = "failed:\(SafeErrorText.describe(error))"
        reportWarning("That choice couldn't be saved.")
        refreshSelectedItemInBackground()
        refreshMarginRowsInBackground()
    }

    private func showSharedMarginReadAloud(_ chosen: ImportedCommentaryInterjection) {
        selectedItem.importedCommentaryInterjections = SharedMarginHearing.replacing(chosen, in: selectedItem.importedCommentaryInterjections)
        noteMarginRowsChanged(forItem: sharedMarginRows.first { $0.interjection.id == chosen.id }?.layer.itemId)
        sharedMarginRows = sharedMarginRows.map {
            $0.interjection.id == chosen.id
                ? SharedMarginRow(interjection: chosen, layer: $0.layer, itemTitle: $0.itemTitle, placement: $0.placement) : $0
        }
    }
}
