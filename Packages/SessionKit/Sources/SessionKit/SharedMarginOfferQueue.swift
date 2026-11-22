/// Which shared Margins have been announced this session, and which of those crossed together are
/// still waiting their turn. A 500 ms tick can cross several shared Margins (one layer, or several
/// friends); only one is offered at a time, and the rest wait here to be offered, in listening
/// order, once the one before has been heard or dismissed (#918).
public struct SharedMarginOfferQueue: Equatable {
    public private(set) var announcedIDs: Set<String> = []
    public private(set) var waitingIDs: [String] = []

    /// The prompt whose card is tone-only (`SharedMarginPromptStyle.isToneOnly`): a newer crossed Margin may replace
    /// it, so a card with no timer (assistive technology, #3720) can't hide every later Margin.
    public var toneOnlyCardID: String?

    public init() {}

    public var isEmpty: Bool { waitingIDs.isEmpty }

    /// One playback tick. Returns the Margin to offer now, if any.
    ///
    /// Margins waiting from before a seek, or from another item, belong to the old position and
    /// are dropped. When nothing else is being offered (`canOffer`), what just crossed is announced
    /// and queued behind any already waiting (Margins in `fresh` reveal mode are announced but never
    /// offered), and the first waiting Margin that can still be offered is returned. `prompts` is
    /// every current prompt, announced or not; it is only read when something may be offered.
    /// `canReplaceCard` is true while a card with no timer (a tone-only card, with VoiceOver or Switch Control, #3720)
    /// is up and nothing else is: a newly crossed Margin may then replace it, and nothing else does.
    /// It runs while this queue is being modified, so it must not read the queue (a stored property
    /// of a class would trap on overlapping access).
    public mutating func nextOffer(
        previous: SessionSnapshot,
        current: SessionSnapshot,
        selectedItemID: String,
        canOffer: Bool,
        canReplaceCard: Bool = false,
        prompts: @autoclosure () -> [ImportedCommentaryPrompt]
    ) -> ImportedCommentaryPrompt? {
        if current.itemId != selectedItemID || Self.isPlayheadJump(previous: previous, current: current) {
            waitingIDs.removeAll()
        }
        // The end of the episode is a moment, not a place: a Margin that plays after the others has no later chance. So
        // when the end is reached while a card or a Margin voice holds the slot, those Margins are queued to wait their
        // turn instead of being dropped with the tick (#4347).
        if !(canOffer || canReplaceCard), current.itemId == selectedItemID,
           FriendMarginsPlan.episodeEndReached(previous: previous, current: current) {
            let waitingForTheEnd = prompts().filter {
                !announcedIDs.contains($0.id) && $0.plan == .afterOthers && $0.layer.revealMode != .fresh
            }
            announcedIDs.formUnion(waitingForTheEnd.map(\.id))
            append(waitingForTheEnd)
        }
        guard canOffer || canReplaceCard, current.itemId == selectedItemID else { return nil }
        let all = prompts()
        let crossed = SharedMarginPrompts.crossed(
            prompts: all.filter { !announcedIDs.contains($0.id) }, previous: previous, current: current
        )
        announcedIDs.formUnion(crossed.map(\.id))
        let offerableCrossed = crossed.filter { $0.layer.revealMode != .fresh }
        append(offerableCrossed)
        // A card that is still up only gives way to a Margin the source just crossed. The Margins already waiting
        // keep waiting behind it, so Margins crossed together are not shown over one another every tick (#918, #3720).
        if !canOffer, offerableCrossed.isEmpty { return nil }
        return next(from: all.filter { $0.layer.revealMode != .fresh })
    }

    /// The next Margin that waits for the end of the episode, once the episode has ended and the slot is free (#4347).
    ///
    /// Playback ticks only run while the source plays, so after the end no tick comes to drain the queue: the first
    /// Margin is offered on the end tick and the rest would wait for ever. The app calls this only where the listener is
    /// done with a Margin and stays at the end (its voice ends, Return to source, the card's Skip, the card timing out),
    /// never from a teardown that clears the slot to do something else. Mid-episode it returns nil, so the ticks keep
    /// offering what crossed together as before.
    public mutating func nextWaitingAtEpisodeEnd(
        snapshot: SessionSnapshot, selectedItemID: String, slotIsFree: Bool,
        offerable: @autoclosure () -> [ImportedCommentaryPrompt]
    ) -> ImportedCommentaryPrompt? {
        guard slotIsFree, !waitingIDs.isEmpty, snapshot.itemId == selectedItemID, !snapshot.status.isPlaybackActive,
              snapshot.currentPlaybackProgressPercent >= ItemFinishedRule.atEndPercent else { return nil }
        return next(from: offerable())
    }

    /// Adds prompts behind any already waiting. A Margin already waiting is not added twice.
    public mutating func append(_ prompts: [ImportedCommentaryPrompt]) {
        for prompt in prompts where !waitingIDs.contains(prompt.id) {
            waitingIDs.append(prompt.id)
        }
    }

    /// The next waiting Margin that can still be offered. `offerable` is the current list of
    /// prompts the listener may be offered (deleted, disabled or replaced Margins are absent),
    /// so one that went away while waiting is dropped instead of offered.
    public mutating func next(from offerable: [ImportedCommentaryPrompt]) -> ImportedCommentaryPrompt? {
        while !waitingIDs.isEmpty {
            let id = waitingIDs.removeFirst()
            if let prompt = offerable.first(where: { $0.id == id }) { return prompt }
        }
        return nil
    }

    /// The listener was offered this Margin some other way (jumped to it, answered it). It is
    /// announced and no longer waits.
    public mutating func markAnnounced(_ id: String) {
        announcedIDs.insert(id)
        waitingIDs.removeAll { $0 == id }
    }

    /// A review of new Margins that stopped short gives back the ones it didn't reach (#474): they
    /// may be offered again when the source crosses them.
    public mutating func markUnannounced(_ ids: Set<String>) {
        announcedIDs.subtract(ids)
    }

    /// A Margin the listener played themselves no longer waits, but may still be offered when
    /// the source crosses it.
    public mutating func remove(id: String) {
        waitingIDs.removeAll { $0 == id }
    }

    /// A new session: nothing is announced and nothing waits.
    public mutating func removeAll() {
        announcedIDs.removeAll()
        waitingIDs.removeAll()
    }

    /// Whether the playhead moved by more than normal listening does between two ticks (a seek, a
    /// skip, a rewind). Margins waiting from before such a move belong to the old position.
    public static func isPlayheadJump(
        previous: SessionSnapshot,
        current: SessionSnapshot,
        maxMediaStepMs: Int = 10_000,
        maxTextStepChars: Int = 2_000
    ) -> Bool {
        if let before = previous.currentMediaTimeMs, let after = current.currentMediaTimeMs {
            return after < before || after - before > maxMediaStepMs
        }
        if let before = previous.currentTextStart, let after = current.currentTextStart {
            return after < before || after - before > maxTextStepChars
        }
        return false
    }
}
