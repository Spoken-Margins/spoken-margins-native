import Foundation
import SessionKit
import SessionKitAudio

/// "Review new Margins" (#474): plays an item's shared Margins that the listener hasn't heard, one after another,
/// each with a short lead-in, through the same conductor as "Play this moment". Which Margins, in what order, and
/// where the source hops between them is decided in SessionKit (`SharedMarginReview`, `MarginMomentSequence`).
/// This file starts the review and marks each Margin heard when its voice starts.
extension Gate1AppModel {
    /// The shared Margins on `itemId` that the listener hasn't heard, in playing order. Reads the open item when it
    /// is the one asked about, else the Library's store.
    func newSharedMargins(itemId: String) -> [SharedMarginReview.Entry] {
        if selectedItem.id == itemId {
            return SharedMarginReview.entries(
                layers: selectedItem.importedCommentaryLayers, records: selectedItem.importedCommentaryInterjections
            )
        }
        guard let store else { return [] }
        return (try? SharedMarginReview.entries(itemId: itemId, in: store)) ?? []
    }

    /// Continue for an item. Starts it, or hands `offer` the item when it has new shared Margins that the listener
    /// should be asked about first: after an import, Continue used to land past them (owner's co-op test).
    func continueListening(itemId: String, offer: (String) -> Void) {
        if newSharedMargins(itemId: itemId).isEmpty { startItem(id: itemId) } else { offer(itemId) }
    }

    /// Plays the new shared Margins on `itemId` in turn. Afterwards the item goes back to where the listener left
    /// off: playing on with `thenContinue`, paused without it.
    func reviewNewMargins(itemId: String, thenContinue: Bool) {
        guard !rejectNavigationOrSessionMutationWhileRecording("review_new_margins") else { return }
        let entries = newSharedMargins(itemId: itemId)
        guard !entries.isEmpty else {
            reportWarning("There are no new Margins to review on this item.")
            return
        }
        endMarginMoment()
        if snapshot.itemId != itemId || !hasActiveSession { startItem(id: itemId) }
        guard snapshot.itemId == itemId,
              let sequence = MarginMomentSequence(
                  itemId: itemId, reviewing: entries.map(\.anchor),
                  returnToMediaTimeMs: snapshot.currentMediaTimeMs, resumesAtEnd: thenContinue
              ) else { return }
        // The review plays these voices; the automatic shared-Margin prompts mustn't play them again.
        announcedImportedInterjectionIDs.formUnion(entries.map(\.interjection.id))
        var voiceURLs: [String: URL] = [:]
        var heard: [String: ImportedCommentaryInterjection] = [:]
        for entry in entries {
            heard[entry.marginId] = entry.interjection
            if let url = entry.interjection.audioPath.flatMap(resolvedApplicationSupportAssetURL(for:)) { voiceURLs[entry.marginId] = url }
        }
        startMarginMoment(sequence: sequence, voiceURLs: voiceURLs, title: "New Margins", isApproximate: false)
        marginMomentConductor?.onVoiceStarted = { [weak self] in
            if let margin = heard[$0] { self?.markSharedMarginHeard(margin) }
        }
        // Their voices get the same chime as the automatic prompt, except for a muted layer's (#932).
        marginMomentConductor?.chimedMarginIds = Set(entries.filter { !$0.layer.isMuted }.map(\.marginId))
        marginMomentConductor?.onChimeStarted = { [weak self] in self?.diagnostics["marginMoment.chime"] = "played:\($0)" }
        if !snapshot.status.isPlaybackActive { resumePlayback() }
        screen = .playback
    }

    /// Stop on the review card: the voice stops and the item goes back to where the listener left off, paused.
    func stopReviewingNewMargins() {
        marginMomentConductor?.stopReview()
        endMarginMoment()
    }
}
