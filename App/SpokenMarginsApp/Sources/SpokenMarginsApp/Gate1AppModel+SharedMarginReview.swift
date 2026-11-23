import Foundation
import SessionKit
import SessionKitAudio

/// The question Continue asks before it starts an item that has new shared Margins (#474): the item, and the Margins
/// the question is about. Read once when Continue is tapped, so the dialog's message and its two answers don't read
/// the store again (#2506): the dialog rebuilds its message on every render while it is up.
struct NewMarginsOfferRequest: Equatable {
    let itemId: String
    let entries: [SharedMarginReview.Entry]
    /// The saved place is the very end of the episode, so the way past the question is "Play from the start", not
    /// "Listen without them" (`PlayRule.askedPlaceIsAtEnd`, #4125). False for the item screen's own requests.
    var placeIsAtEnd = false
    /// The item is finished and a reply answers the listener (#4785): the question offers "Hear Cole's replies", which
    /// plays only these and pauses after them.
    var catchUp: ConversationCatchUp?
    /// In catch-up, the second answer is "Continue" (a re-listen short of the end) rather than "Play from the start".
    var catchUpContinues = false
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
                ownMargins: ownMargins(itemId: itemId), durationMs: selectedItem.mediaDurationMs
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

    /// When the listener last added the item again, from what the model holds, so no read runs: the open item and the
    /// Library row. A re-add from Safari or a link refreshes only the row, and the open item keeps the stamp it loaded
    /// with, so the later of the two is the true one (#4183).
    func addedAgainAt(forItem id: String) -> Date? {
        ItemFinishedRule.laterAddedAgainAt(
            selectedItem.id == id ? selectedItem.addedAgainAt : nil,
            libraryItems.first(where: { $0.id == id })?.addedAgainAt)
    }

    /// The open item's sessions that still decide its primary button and where Play starts (#4183). The history on the
    /// screen, `selectedItem.sessions`, keeps every pass.
    var selectedItemContinuationSessions: [Session] {
        ItemFinishedRule.continuationSessions(addedAgainAt: addedAgainAt(forItem: selectedItem.id), sessions: selectedItem.sessions)
    }

    /// Play or Continue for an item. What it does, and whether it asks first, is `PlayRule` (SessionKit, #4099): a
    /// friend's Margins play in place as the episode reaches them (owner's call on #3059: no question first), and the
    /// one case it asks is the one the episode would skip: new Margins behind the listener's place, after an import
    /// into an episode they were partway through (owner's co-op test, #474). `offer` gets the item with only those
    /// Margins. An offer the listener already turned down isn't made again until another Margin arrives. This reads
    /// only what the model already holds (no store read on the main thread); `startItem` reads the sessions.
    ///
    /// `offersCatchUp` (#4785): only the Library row's play button passes it. A finished item with a reply to the listener
    /// then asks "New replies to hear" at 100% and on the mark too, from the row and the entries already held.
    func continueListening(
        itemId: String, surface: PlayRule.Surface = .libraryRow, offersCatchUp: Bool = false, offer: (NewMarginsOfferRequest) -> Void
    ) {
        var context = PlayRule.Context(
            itemId: itemId, surface: surface,
            nowPlaying: hasActiveSession ? snapshot.itemId.map { PlayRule.NowPlaying(itemId: $0, mediaTimeMs: snapshot.currentMediaTimeMs) } : nil,
            openItem: PlayRule.OpenItem(id: selectedItem.id, sessions: selectedItem.sessions, addedAgainAt: addedAgainAt(forItem: selectedItem.id)),
            libraryRow: libraryItems.first(where: { $0.id == itemId }),
            // Only the Library row asks about Margins, so the item screen skips the read.
            newMargins: surface == .libraryRow ? newSharedMargins(itemId: itemId) : [],
            declined: Self.declinedNewMargins)
        if offersCatchUp, surface == .libraryRow, let row = context.libraryRow {
            context.catchUp = ConversationCatchUp.make(isFinished: row.isCompleted, entries: context.newMargins)
        }
        switch PlayRule.decide(context) {
        case .play: startItem(id: itemId)
        case .askFirst(let entries):
            var request = NewMarginsOfferRequest(itemId: itemId, entries: entries, placeIsAtEnd: PlayRule.askedPlaceIsAtEnd(context))
            if let catchUp = context.catchUp {
                request.catchUp = catchUp
                let row = context.libraryRow
                request.catchUpContinues = row?.hasContinuationSession == true
                    && (row?.continuationProgressPercent ?? 100) < ItemFinishedRule.listenedPercent
            }
            offer(request)
        }
    }

    /// "Listen without them" on the offer: starts the item, and doesn't ask about these Margins again.
    func continueWithoutNewMargins(_ offer: NewMarginsOfferRequest) {
        Self.declinedNewMargins.decline(itemId: offer.itemId, margins: offer.entries.map(\.marginId))
        startItem(id: offer.itemId)
    }

    /// The friend Margins behind the place Play would resume on the open item, for the item screen's two pinned buttons
    /// (#4125). Empty when none is, or when the listener turned them down in this run. The rule is `PlayRule`'s.
    func itemScreenMarginsBehindSavedPlace(itemId: String) -> [SharedMarginReview.Entry] {
        guard selectedItem.id == itemId else { return [] }
        return PlayRule.itemScreenMarginsBehind(
            newSharedMargins(itemId: itemId), itemId: itemId, sessions: selectedItem.sessions,
            addedAgainAt: addedAgainAt(forItem: itemId), declined: Self.declinedNewMargins)
    }

    /// Whether the open item's saved place is its very end, from `PlayRule` (#4125).
    func selectedItemSavedPlaceIsAtEnd() -> Bool {
        PlayRule.savedPlaceIsAtEnd(sessions: selectedItem.sessions, addedAgainAt: addedAgainAt(forItem: selectedItem.id))
    }

    /// What starting an item does before its session begins, for every way of starting it: the imported audio bridges, the
    /// community map, the publisher voiceover lookup, and opening audio that is still being prepared. False when a
    /// recording in progress blocks the start.
    func prepareToStartItem(id: String) -> Bool {
        guard !rejectNavigationOrSessionMutationWhileRecording("start_item") else { return false }
        prepareImportedLocalAudioBridges(itemId: id); fetchCommunityMapIfNeeded(itemId: id); listenerStartedItem(itemId: id)
        if [.waiting, .preparing].contains(libraryItems.first(where: { $0.id == id })?.startupAudioState) {
            scheduleStartupAudioPreparationIfNeeded(itemId: id)
            diagnostics["startupAudioPlayback:\(id)"] = "started_without_waiting_for_opening_buffer"
        }
        return true
    }

    /// "Play from the start" on the item screen and the Library row's question: leaves these Margins new, doesn't ask about them again this run, and
    /// begins a new session at 0, where they are ahead and play in place. The old session stays, so there is no
    /// "Start a separate listening session?" question (#4125).
    func startItemFromBeginning(itemId: String, entries: [SharedMarginReview.Entry]) {
        // The Library row's question reaches here without the item ever having been opened, so it does what `startItem`
        // does before a session starts, not only what opening the item screen did (#4125).
        guard prepareToStartItem(id: itemId) else { return }
        Self.declinedNewMargins.decline(itemId: itemId, margins: entries.map(\.marginId))
        startNewSession(id: itemId)
    }

    /// Plays the new shared Margins on `itemId` in turn. Afterwards the item goes back to where the listener left
    /// off: playing on with `thenContinue`, paused without it. `entries` are the Margins an offer already read; without
    /// them the review reads them.
    ///
    /// `catchUp` (#4785): the item is finished and a reply answers the listener. The run starts its own session
    /// (`startCatchUpSession`), never in a finished one, and pauses after the last reply instead of playing on.
    func reviewNewMargins(
        itemId: String, thenContinue: Bool, entries offered: [SharedMarginReview.Entry]? = nil,
        startingEarlier: StartEarlier.Plan? = nil, catchUp: Bool = false
    ) {
        guard !rejectNavigationOrSessionMutationWhileRecording("review_new_margins") else { return }
        if catchUp, catchUpRunIsPlaying(itemId: itemId) { return } // a second tap starts one run, not two
        let entries = offered ?? newSharedMargins(itemId: itemId)
        guard !entries.isEmpty else {
            reportWarning("There are no new Margins to review here.")
            return
        }
        if reviewFriendMarginsOfDeadEpisode(itemId: itemId, entries: entries) { return } // the episode can't play (#3392)
        if WrittenMarginReadings.holdReview(itemId: itemId, thenContinue: thenContinue, entries: entries, catchUp: catchUp, model: self) { return } // readings not ready yet (#3365)
        endMarginMoment()
        // A Margin voice already playing (your own, #1538, or a friend's) or a shared-Margin card waiting gives way:
        // it would play over the review, and its end would resume the source mid-review.
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        pendingImportedCommentary = nil
        _ = sharedMarginReturn.promptDismissed()
        stopImportedCommentaryPlayback(resumeSource: false)
        var catchUpReturnTo: Int?
        if catchUp {
            guard let started = startCatchUpSession(itemId: itemId) else { return } // offline or refused: the replies stay new
            catchUpReturnTo = started.returnToMediaTimeMs
        } else if snapshot.itemId != itemId || !hasActiveSession {
            startItem(id: itemId)
        }
        // A friend's reply to one of the listener's own spoken Margins plays after that Margin (#3221): the lead-in,
        // the Margin, then the reply. Skip on the card goes past the Margin to the reply.
        var voiceURLs: [String: URL] = [:]
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: ownMargins(itemId: itemId)).filter { step in
            guard let parent = step.ownParent else { return true }
            guard let url = parent.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) else { return false }
            voiceURLs[step.anchor.marginId] = url
            return true
        }
        // "Start a minute earlier" on a friend's Margin playing by itself (#4171) reviews that Margin with the longer run-up.
        let reviewing = steps.map(\.anchor)
        let built: MarginMomentSequence?
        if let startingEarlier {
            // No return place: Stop in the longer run-up pauses where it is, never a minute ahead at the Margin, and the
            // episode plays on from the Margin after it (the Design's "Stop after a reached Margin").
            built = StartEarlier.review(itemId: itemId, margins: reviewing, plan: startingEarlier)
        } else {
            built = MarginMomentSequence(
                itemId: itemId, reviewing: reviewing, returnToMediaTimeMs: catchUp ? catchUpReturnTo : snapshot.currentMediaTimeMs,
                resumesAtEnd: thenContinue && !catchUp, endsPaused: catchUp)
        }
        guard snapshot.itemId == itemId, let sequence = built else { return }
        // The review plays these voices; the automatic shared-Margin prompts mustn't play them again.
        entries.forEach { sharedMarginOffers.markAnnounced($0.interjection.id) }
        // Written down before the review first moves the source, for the endings it can't give the place back at.
        if let place = ReviewReturnPlace(sequence: sequence) { reviewPlaces.owe(place) }
        var heard: [String: ImportedCommentaryInterjection] = [:]
        for entry in entries { heard[entry.marginId] = entry.interjection }
        // Each Margin's recording, or its reading (rendered now if need be), from `SharedMarginAudio` (#3365, #3412).
        voiceURLs.merge(WrittenMarginReadings.startingReview(for: entries, voiceFile: resolvedApplicationSupportAssetURL(for:))) { voice, _ in voice }
        startMarginMoment(sequence: sequence, voiceURLs: voiceURLs, title: "New Margins", isApproximate: false)
        if catchUp { beginCatchUpRun(itemId: itemId, entries: entries) }
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
        noteCatchUp(.stopped) // a catch-up run that ends early shows no card; the rest stay new (#4785)
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
