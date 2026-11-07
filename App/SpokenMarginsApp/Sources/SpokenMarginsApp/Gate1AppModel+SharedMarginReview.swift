import Foundation
import SessionKit
import SessionKitAudio

/// The question Continue asks before it starts an item that has new shared Margins (#474): the item, and the Margins
/// the question is about. Read once when Continue is tapped, so the dialog's message and its two answers don't read
/// the store again (#2506): the dialog rebuilds its message on every render while it is up.
struct NewMarginsOfferRequest: Equatable {
    let itemId: String
    let entries: [SharedMarginReview.Entry]
}

/// "Review new Margins" (#474): plays an item's shared Margins that the listener hasn't heard, one after another,
/// each with a short lead-in, through the same conductor as "Play this moment". Which Margins, in what order, and
/// where the source hops between them is decided in SessionKit (`SharedMarginReview`, `MarginMomentSequence`).
/// This file starts the review and marks each Margin heard when its voice starts.
extension Gate1AppModel {
    /// What the listener turned down on the offer, for the life of the app. See `NewMarginsOfferMemory`.
    private static var declinedNewMargins = NewMarginsOfferMemory()

    /// The shared Margins on `itemId` that the listener hasn't heard, in playing order. Reads the open item when it
    /// is the one asked about, else the Library's store. A Margin whose recording is gone is left out: it can't be
    /// played, and nothing would ever mark it heard. A written Margin has no recording; its words are read (#3365).
    func newSharedMargins(itemId: String) -> [SharedMarginReview.Entry] {
        let entries: [SharedMarginReview.Entry]
        if let dead = deadEpisodeEntries(itemId: itemId) { // a dead podcast episode: its Margins are unplaced (#3392)
            entries = dead
        } else if selectedItem.id == itemId {
            entries = SharedMarginReview.entries(
                layers: selectedItem.importedCommentaryLayers, records: selectedItem.importedCommentaryInterjections,
                ownMargins: ownMargins(itemId: itemId)
            )
        } else if let store {
            // The listener's own Margins let a friend's reply say which of them it answers (#3221). They come from the
            // Margins screen's published rows, so this adds no store read to the main thread.
            entries = (try? SharedMarginReview.entries(
                itemId: itemId, in: store, ownMargins: ownMargins(itemId: itemId), hiddenSenders: hiddenSenders.current)) ?? []
        } else {
            entries = []
        }
        return entries.filter { WrittenMarginReadings.audio(for: $0.interjection, in: $0.layer, voiceFile: resolvedApplicationSupportAssetURL(for:)).file != nil }
    }

    /// The listener's own Margins on `itemId`, read from what the app already holds: the open item's and the rows the
    /// Margins screen published. The open item holds one session's Margins, so alone it misses a Margin shared from
    /// another session, and a friend's reply to it reads "a Margin you don't have yet" (#3353).
    func ownMargins(itemId: String) -> [Interjection] {
        SharedMarginReview.ownMargins(
            itemId: itemId,
            openItem: selectedItem.id == itemId ? selectedItem.interjections : [],
            rows: marginRows.lazy.filter { $0.interjection.itemId == itemId }.map(\.interjection)
        )
    }

    /// Continue for an item. Starts it, and a friend's Margins play in place as it reaches them (owner's call on
    /// #3059: the big button plays the episode with them on auto-play, no question first). The one case it still asks
    /// is the one the episode would skip: new Margins behind the listener's place, after an import into an episode
    /// they were partway through (owner's co-op test, #474). `offer` gets the item with only those Margins. An offer
    /// the listener already turned down isn't made again until another Margin arrives.
    func continueListening(itemId: String, offer: (NewMarginsOfferRequest) -> Void) {
        let entries = SharedMarginReview.entriesBehind(newSharedMargins(itemId: itemId), placeMs: listenerPlaceMs(itemId: itemId))
        let new = entries.map(\.marginId)
        if new.isEmpty || Self.declinedNewMargins.isDeclined(itemId: itemId, margins: new) {
            startItem(id: itemId)
        } else {
            offer(NewMarginsOfferRequest(itemId: itemId, entries: entries))
        }
    }

    /// Where Continue would start `itemId`, in media milliseconds, from what the model already holds (no store read on
    /// the main thread): the open item's playhead, else the place the selected item's continuing session was left at.
    /// An episode not begun, or finished, starts at 0. Nil when it can't be told cheaply: a started episode in the
    /// Library that isn't the selected item. Continue then asks about every new Margin, as it always did.
    private func listenerPlaceMs(itemId: String) -> Int? {
        if hasActiveSession, snapshot.itemId == itemId { return snapshot.currentMediaTimeMs ?? 0 }
        if selectedItem.id == itemId {
            guard let continuation = selectedItemPreferredContinuationSession,
                  continuation.phase != .finished, continuation.status != "finished", continuation.completionPercent < 100 else { return 0 }
            return continuation.position.mediaTimeMs ?? 0
        }
        guard let row = libraryItems.first(where: { $0.id == itemId }) else { return 0 }
        return row.hasContinuationSession && !row.isCompleted ? nil : 0
    }

    /// "Listen without them" on the offer: starts the item, and doesn't ask about these Margins again.
    func continueWithoutNewMargins(_ offer: NewMarginsOfferRequest) {
        Self.declinedNewMargins.decline(itemId: offer.itemId, margins: offer.entries.map(\.marginId))
        startItem(id: offer.itemId)
    }

    /// Plays the new shared Margins on `itemId` in turn. Afterwards the item goes back to where the listener left
    /// off: playing on with `thenContinue`, paused without it. `entries` are the Margins an offer already read; without
    /// them the review reads them.
    func reviewNewMargins(itemId: String, thenContinue: Bool, entries offered: [SharedMarginReview.Entry]? = nil) {
        guard !rejectNavigationOrSessionMutationWhileRecording("review_new_margins") else { return }
        let entries = offered ?? newSharedMargins(itemId: itemId)
        guard !entries.isEmpty else {
            reportWarning("There are no new Margins to review on this item.")
            return
        }
        if reviewFriendMarginsOfDeadEpisode(itemId: itemId, entries: entries) { return } // the episode can't play (#3392)
        if WrittenMarginReadings.holdReview(itemId: itemId, thenContinue: thenContinue, entries: entries, model: self) { return } // readings not ready yet (#3365)
        endMarginMoment()
        // A Margin voice already playing (your own, #1538, or a friend's) or a shared-Margin card waiting gives way:
        // it would play over the review, and its end would resume the source mid-review.
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        pendingImportedCommentary = nil
        _ = sharedMarginReturn.promptDismissed()
        stopImportedCommentaryPlayback(resumeSource: false)
        if snapshot.itemId != itemId || !hasActiveSession { startItem(id: itemId) }
        // A friend's reply to one of the listener's own spoken Margins plays after that Margin (#3221): the lead-in,
        // the Margin, then the reply. Skip on the card goes past the Margin to the reply.
        var voiceURLs: [String: URL] = [:]
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: ownMargins(itemId: itemId)).filter { step in
            guard let parent = step.ownParent else { return true }
            guard let url = parent.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) else { return false }
            voiceURLs[step.anchor.marginId] = url
            return true
        }
        guard snapshot.itemId == itemId,
              let sequence = MarginMomentSequence(
                  itemId: itemId, reviewing: steps.map(\.anchor),
                  returnToMediaTimeMs: snapshot.currentMediaTimeMs, resumesAtEnd: thenContinue
              ) else { return }
        // The review plays these voices; the automatic shared-Margin prompts mustn't play them again.
        entries.forEach { sharedMarginOffers.markAnnounced($0.interjection.id) }
        // Written down before the review first moves the source, for the endings it can't give the place back at.
        if let place = ReviewReturnPlace(sequence: sequence) { reviewPlaces.owe(place) }
        var heard: [String: ImportedCommentaryInterjection] = [:]
        for entry in entries { heard[entry.marginId] = entry.interjection }
        // Each Margin's recording, or its reading (rendered now if need be), from `SharedMarginAudio` (#3365, #3412).
        voiceURLs.merge(WrittenMarginReadings.startingReview(for: entries, voiceFile: resolvedApplicationSupportAssetURL(for:))) { voice, _ in voice }
        startMarginMoment(sequence: sequence, voiceURLs: voiceURLs, title: "New Margins", isApproximate: false)
        marginMomentConductor?.onVoiceStarted = { [weak self] in
            if let margin = heard[$0] { self?.markSharedMarginHeard(margin) }
        }
        settleReviewPlaceAsTheReviewProgresses(itemId: itemId)
        // Their voices get the same chime as the automatic prompt, except for a muted layer's (#932).
        marginMomentConductor?.chimedMarginIds = SharedMarginReview.chimedMarginIds(steps)
        marginMomentConductor?.onChimeStarted = { [weak self] in self?.diagnostics["marginMoment.chime"] = "played:\($0)" }
        WrittenMarginReadings.rewordUnavailable(on: marginMomentConductor, entries: entries, model: self)
        if !snapshot.status.isPlaybackActive { resumePlayback() }
        screen = .playback
    }

    /// The review's note of the listener's place follows the review: a Margin has the floor once the sequence says so,
    /// whether or not its voice ever starts (an unplayable voice, a chime still sounding), and that is what matters to a
    /// relaunch (#3626). So it is read on every change of the sequence, not from the voice's start.
    private func settleReviewPlaceAsTheReviewProgresses(itemId: String) {
        guard let conductor = marginMomentConductor else { return }
        let existing = conductor.onChange
        conductor.onChange = { [weak self, weak conductor] in
            if let self, let conductor, self.marginMomentConductor === conductor {
                self.settleReviewPlace(itemId: itemId, reviewIs: conductor.sequence)
            }
            existing?()
        }
    }

    /// Once a Margin of the review has the floor, the episode plays on from it, so the saved session is the listener's own
    /// listening and a relaunch must not hand back the place the review started from. The note stays only for a listener
    /// whose place was ahead of the Margin, and then only to bring back a position still behind it
    /// (`ReviewReturnPlace.standing(whenReviewIs:)`, audit of #3619).
    func settleReviewPlace(itemId: String, reviewIs sequence: MarginMomentSequence) {
        guard sequence.hasReachedAMargin, sequence.playing != nil, let place = reviewPlaces.owed(itemId: itemId) else { return }
        switch place.standing(whenReviewIs: sequence) {
        case .owed(let kept): if kept != place { reviewPlaces.owe(kept) }
        case .released: reviewPlaces.clear(itemId: itemId)
        }
    }

    /// Stop on the review card: the voice stops and the item goes back to where the listener left off, paused.
    func stopReviewingNewMargins() {
        endMarginMoment()
    }

    /// A review that ends before its last Margin (Stop, another item, a Timeline jump, the session closing, a new
    /// review) hands the item back as the listener left it: the voice stops, the source goes back to where they left
    /// off, paused, and the Margins it didn't reach go back to the automatic prompts. Without that, the session is
    /// saved wherever the review had got to and the next Continue lands there. Called first whenever a moment ends.
    /// The source only moves while it is still on the review's item: once another item has taken the player, the
    /// place belongs to the item that was left, not to the new one.
    func giveBackUnfinishedReview() {
        guard let conductor = marginMomentConductor, conductor.sequence.isReview else { return }
        let itemId = conductor.sequence.itemId
        guard conductor.sequence.isUnfinishedReview else { return reviewPlaces.clear(itemId: itemId) }
        releaseUnplayedReviewMargins()
        if snapshot.itemId == itemId { conductor.stopReview() }
        reviewPlaces.clear(itemId: itemId)
    }

    /// At launch, the saved session of a review the app never finished (iOS ended the app mid-review, so nothing ran
    /// the review's own ending) is wherever the review had got to. Puts the source back at the listener's place, and
    /// leaves no other place owed. A position outside the stretch the review covers is left alone, because the
    /// listener got there themselves.
    func settleReviewPlacesAtLaunch() {
        defer { if marginMomentConductor == nil { reviewPlaces.removeAll() } }
        guard !snapshot.isRecording, marginMomentConductor == nil, let itemId = snapshot.itemId,
              let place = reviewPlaces.owed(itemId: itemId) else { return }
        reviewPlaces.clear(itemId: itemId)
        guard place.needsRestoring(from: snapshot.currentMediaTimeMs) else { return }
        seekMedia(toMediaTimeMs: place.returnToMediaTimeMs)
    }

    /// For the places that stop the player or start another session before they end a moment (opening, resuming or
    /// starting a session): an unfinished review ends first, while the source is still on its item, so that item is
    /// saved at the listener's place. It runs before they clear the shared-Margin prompts, so the jump back doesn't
    /// count as passing a Margin the review already played.
    func endUnfinishedReview() {
        if marginMomentConductor?.sequence.isUnfinishedReview == true { endMarginMoment() }
    }

    /// A review that ends before it reaches every Margin gives back the ones still ahead of the place it will return
    /// to, so the automatic prompts play them when the listener gets there. The ones behind that place stay
    /// announced: going back to the place would otherwise count as passing them.
    private func releaseUnplayedReviewMargins() {
        guard let moment = marginMoment, let review = moment.review, moment.itemId == selectedItem.id else { return }
        let returnTo = review.returnToMediaTimeMs ?? 0
        var left = moment.unplayed
        if let playing = moment.playing { left.append(playing) }
        let ahead = CantPlayListening.isCantPlayListening(moment)
            ? CantPlayListening.unreachedMarginIds(in: moment) // one flat place: every unplayed Margin goes back (#3392)
            : Set(left.filter { $0.mediaTimeMs > returnTo }.map(\.marginId))
        guard !ahead.isEmpty else { return }
        let stillNew = selectedItem.importedCommentaryInterjections.values.joined().filter {
            $0.isNewToListener && ahead.contains(SharedMarginReview.marginId(layerId: $0.layerId, interjectionId: $0.id))
        }
        sharedMarginOffers.markUnannounced(Set(stillNew.map(\.id)))
    }
}
