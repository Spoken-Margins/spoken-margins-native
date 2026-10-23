/// Which shared Margins have been announced this session, and which of those crossed together are
/// still waiting their turn. A 500 ms tick can cross several shared Margins (one layer, or several
/// friends); only one is offered at a time, and the rest wait here to be offered, in listening
/// order, once the one before has been heard or dismissed (#918).
public struct SharedMarginOfferQueue: Equatable {
    public private(set) var announcedIDs: Set<String> = []
    public private(set) var waitingIDs: [String] = []

    public init() {}

    public var isEmpty: Bool { waitingIDs.isEmpty }

    /// One playback tick. Returns the Margin to offer now, if any.
    ///
    /// Margins waiting from before a seek, or from another item, belong to the old position and
    /// are dropped. When nothing else is being offered (`canOffer`), what just crossed is announced
    /// and queued behind any already waiting (Margins in `fresh` reveal mode are announced but never
    /// offered), and the first waiting Margin that can still be offered is returned. `prompts` is
    /// every current prompt, announced or not; it is only read when something may be offered.
    /// It runs while this queue is being modified, so it must not read the queue (a stored property
    /// of a class would trap on overlapping access).
    public mutating func nextOffer(
        previous: SessionSnapshot,
        current: SessionSnapshot,
        selectedItemID: String,
        canOffer: Bool,
        prompts: @autoclosure () -> [ImportedCommentaryPrompt]
    ) -> ImportedCommentaryPrompt? {
        if current.itemId != selectedItemID || Self.isPlayheadJump(previous: previous, current: current) {
            waitingIDs.removeAll()
        }
        guard canOffer, current.itemId == selectedItemID else { return nil }
        let all = prompts()
        let crossed = SharedMarginPrompts.crossed(
            prompts: all.filter { !announcedIDs.contains($0.id) }, previous: previous, current: current
        )
        announcedIDs.formUnion(crossed.map(\.id))
        append(crossed.filter { $0.layer.revealMode != .fresh })
        return next(from: all.filter { $0.layer.revealMode != .fresh })
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
