import Foundation
import SessionKit
import SessionKitAudio

/// "Review new Margins" (#474): plays an item's shared Margins that the listener hasn't heard, one after another,
/// each with a short lead-in, through the same conductor as "Play this moment". Which Margins, in what order, and
/// where the source hops between them is decided in SessionKit (`SharedMarginReview`, `MarginMomentSequence`).
/// This file starts the review and marks each Margin heard when its voice starts.
extension Gate1AppModel {
    /// What the listener turned down on the offer, for the life of the app. See `NewMarginsOfferMemory`.
    private static var declinedNewMargins = NewMarginsOfferMemory()

    /// The shared Margins on `itemId` that the listener hasn't heard, in playing order. Reads the open item when it
    /// is the one asked about, else the Library's store. A Margin whose recording is gone is left out: it can't be
    /// played, and nothing would ever mark it heard.
    func newSharedMargins(itemId: String) -> [SharedMarginReview.Entry] {
        let entries: [SharedMarginReview.Entry]
        if selectedItem.id == itemId {
            entries = SharedMarginReview.entries(
                layers: selectedItem.importedCommentaryLayers, records: selectedItem.importedCommentaryInterjections
            )
        } else if let store {
            entries = (try? SharedMarginReview.entries(itemId: itemId, in: store)) ?? []
        } else {
            entries = []
        }
        return entries.filter { $0.interjection.audioPath.flatMap(resolvedApplicationSupportAssetURL(for:)) != nil }
    }

    /// Continue for an item. Starts it, or hands `offer` the item when it has new shared Margins that the listener
    /// should be asked about first: after an import, Continue used to land past them (owner's co-op test). An offer
    /// the listener already turned down isn't made again until another Margin arrives.
    func continueListening(itemId: String, offer: (String) -> Void) {
        let new = newSharedMargins(itemId: itemId).map(\.marginId)
        if new.isEmpty || Self.declinedNewMargins.isDeclined(itemId: itemId, margins: new) {
            startItem(id: itemId)
        } else {
            offer(itemId)
        }
    }

    /// "Listen without them" on the offer: starts the item, and doesn't ask about these Margins again.
    func continueWithoutNewMargins(itemId: String) {
        Self.declinedNewMargins.decline(itemId: itemId, margins: newSharedMargins(itemId: itemId).map(\.marginId))
        startItem(id: itemId)
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
        entries.forEach { sharedMarginOffers.markAnnounced($0.interjection.id) }
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

    /// A review that ends before it reaches every Margin gives back the ones still ahead of the place it will return
    /// to, so the automatic prompts play them when the listener gets there. The ones behind that place stay
    /// announced: going back to the place would otherwise count as passing them. Called when any moment ends.
    func releaseUnplayedReviewMargins() {
        guard let moment = marginMoment, let review = moment.review, moment.itemId == selectedItem.id else { return }
        let returnTo = review.returnToMediaTimeMs ?? 0
        var left = moment.unplayed
        if let playing = moment.playing { left.append(playing) }
        let ahead = Set(left.filter { $0.mediaTimeMs > returnTo }.map(\.marginId))
        guard !ahead.isEmpty else { return }
        let stillNew = selectedItem.importedCommentaryInterjections.values.joined().filter {
            $0.isNewToListener && ahead.contains(SharedMarginReview.marginId(layerId: $0.layerId, interjectionId: $0.id))
        }
        sharedMarginOffers.markUnannounced(Set(stillNew.map(\.id)))
    }
}
