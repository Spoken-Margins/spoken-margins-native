import Foundation

/// What "Chime where cited" does at each cited note, as a pure state machine (#3777, Design PR 6). The player asks it
/// before it starts each chunk; it says whether to play the chunk, or to cue the note (pause, one tone, raise the
/// card) and carry on past it, or to pass over it silently. Nothing calls it yet: the audio conductor, the Settings
/// picker's third choice and the card's Hear note button are wired to it in the visible PR, so this slice is host-tested
/// alone and reaches no listener.
///
/// The plan carries the same aside chunks in `whereCited` and `chime` (one prepared-audio identity, Design Defaults
/// taken 9). `whereCited` plays them; `chime` passes over them at play time unless the listener asked for a note, so
/// this type does nothing in any other mode.
///
/// A **run** is the asides at one citation: a sentence that cites three notes has three notes' chunks in a row, and gets
/// one tone, one card (for its first note) and one "Hear note" that reads the whole run in citation order (Design, Flow
/// 5 and Matching rule 5). Time never enters here except as a number the caller passes, so every rule is testable
/// without a clock.
public struct FootnoteChimeSequencer: Equatable, Sendable {
    public typealias Tag = NarrationChunkPlanner.FootnoteTag

    /// How long the card stays after the tone when nothing else replaces it (Design, Flow 5).
    public static let cardLifetime: TimeInterval = 30

    /// The aside chunks at one citation.
    public struct Run: Equatable, Sendable {
        /// The plan's chunk indices of every aside at this citation.
        public let chunks: Range<Int>
        /// The notes' labels in citation order, each once (a note longer than the chunk budget is several chunks).
        public let labels: [String]

        public var firstLabel: String { labels[0] }
    }

    /// What the player does with the chunk it is about to start.
    public enum Step: Equatable, Sendable {
        /// Play the chunk as the plan says. Every body chunk, every definition chunk (passing over a heard note's is
        /// `FootnoteHeardSet.skips`, which the player applies in every inline mode), and every aside in a mode other
        /// than `chime` or one the listener asked for.
        case play
        /// Pass over the run without a sound or a card: the app is not active, or every note in the run was heard
        /// already. `continueAt` is the first chunk to play, nil at the end of the text.
        case skip(continueAt: Int?)
        /// Pause, play the tone, raise the card for `run`, and carry on at `continueAt` (nil at the end of the text),
        /// which is the sentence after the citation. The note is not read unless the listener taps Hear note.
        case cue(run: Run, continueAt: Int?)
    }

    /// The card on Now, from this type's side (Design, Screens). The view adds its look and the friend-card rule.
    public enum Card: Equatable, Sendable {
        case hidden
        /// The tone sounded: the card offers Hear note.
        case offered(label: String)
        /// A note is being read: the card's header gains "· Reading" and its button reads Stop note.
        case reading(label: String)

        public var label: String? {
            switch self {
            case .hidden: nil
            case .offered(let label), .reading(let label): label
            }
        }
    }

    public private(set) var card: Card = .hidden

    private var offered: Run?
    /// The note the card names: the first of the run the listener has not heard.
    private var offeredLabel: String?
    private var hearing: Run?
    private var shownAt: TimeInterval?

    public init() {}

    // MARK: - Before each chunk

    /// Called when the player is about to start the chunk at `index`.
    ///
    /// - `tags`: the plan's chunks' `footnote` tags in order.
    /// - `heard`: this session's heard notes; a note read where it was cited is not offered again.
    /// - `now`: seconds on any monotonic clock, used only for the card's 30 seconds.
    ///
    /// The player also calls this with `index == tags.count` when the text ends, or calls `reset()`: a note read to
    /// the text's last chunk has no later chunk to ask about, and that call is what clears its "Reading" card.
    public mutating func willStartChunk(
        at index: Int,
        tags: [Tag?],
        itemId: String,
        mode: FootnoteMode,
        appIsActive: Bool,
        heard: FootnoteHeardSet,
        now: TimeInterval
    ) -> Step {
        guard mode == .chime, tags.indices.contains(index) else {
            // A mode change, or the end of the text: nothing is offered or read any more.
            if hearing != nil || offered != nil { reset() }
            return .play
        }
        rebaseRuns(onto: tags)
        if let hearing {
            // The chunks that lead into the note belong to the request too: the Hear note seek lands on the citing sentence, and a
            // rebuilt plan can put more than one chunk of it before the note (a stand-in voice cuts a long first chunk in two).
            // A listener's own move back is cleared by the player at the seek (`chimeMoveStartedAt`), not here.
            if hearing.chunks.contains(index) || index < hearing.chunks.lowerBound { return .play }
            // The note was read to its end, or the player moved on past it: the card has done its job.
            self.hearing = nil
            if card.isReading { clearCard() }
        }
        guard FootnoteNoteControls.isAside(at: index, tags: tags),
              let run = Self.run(containing: index, tags: tags) else { return .play }
        let continueAt = heard.firstPlayableIndex(from: run.chunks.upperBound, tags: tags, itemId: itemId)
        // Only the start of a run cues. A play that begins inside one (a resume, a seek) passes it silently.
        guard index == run.chunks.lowerBound, appIsActive,
              let firstUnheard = run.labels.first(where: { !heard.hasHeardNote($0, itemId: itemId) }) else {
            // A silent pass is still the next footnote: the card of an earlier citation goes away (Design, Flow 5).
            if offered != run, case .offered = card { clearCard() }
            return .skip(continueAt: continueAt)
        }
        offered = run
        offeredLabel = firstUnheard
        card = .offered(label: firstUnheard)
        shownAt = now
        return .cue(run: run, continueAt: continueAt)
    }

    // MARK: - The listener's moves

    /// The listener asked for the note at `index` (the card's Hear note, or a Timeline entry): the whole run it belongs
    /// to is read, in citation order, and playback then goes on with the chunk after it. Returns the chunk to move
    /// playback to, the run's first, or nil when `index` is not an aside.
    public mutating func beginHearing(chunkAt index: Int, tags: [Tag?]) -> Int? {
        guard let run = Self.run(containing: index, tags: tags) else { return nil }
        hearing = run
        offered = run
        offeredLabel = nil
        card = .reading(label: Self.label(of: index, tags: tags) ?? run.firstLabel)
        shownAt = nil
        return run.chunks.lowerBound
    }

    /// The card's Hear note button: reads the run the card is offering. Nil when no card is offered.
    public mutating func hearOfferedNote(tags: [Tag?]) -> Int? {
        rebaseRuns(onto: tags)
        guard case .offered = card, let run = offered else { return nil }
        let label = offeredLabel
        let start = beginHearing(chunkAt: run.chunks.lowerBound, tags: tags)
        if let label { card = .reading(label: label) }
        return start
    }

    /// The card's Stop note button: ends the reading and goes on with the main text. `continueAt` is the first chunk
    /// to play after the run, nil at the end of the text. Nil when no note is being read.
    public mutating func stopHearing(tags: [Tag?], itemId: String, heard: FootnoteHeardSet) -> Resume? {
        rebaseRuns(onto: tags)
        guard let hearing else { return nil }
        let next = heard.firstPlayableIndex(from: hearing.chunks.upperBound, tags: tags, itemId: itemId)
        self.hearing = nil
        clearCard()
        return Resume(continueAt: next)
    }

    /// Where playback goes on after Stop note.
    public struct Resume: Equatable, Sendable {
        public let continueAt: Int?
    }

    /// Whether the card should go away now: 30 seconds after the tone, never while it is being read, and never while
    /// VoiceOver focus is on it (Design, Flow 5). Returns true when it did.
    @discardableResult
    public mutating func expireCard(now: TimeInterval, voiceOverIsOnCard: Bool) -> Bool {
        guard case .offered = card, let shownAt, !voiceOverIsOnCard,
              now - shownAt >= Self.cardLifetime else { return false }
        clearCard()
        return true
    }

    /// A new item, a recording, a seek the sequencer did not make, or leaving playback: nothing is offered.
    public mutating func reset() {
        hearing = nil
        clearCard()
    }

    /// The player rebuilds its plan (a seek past a split chunk, a stand-in voice that cuts the first chunk in two, a split chunk put
    /// back together), and the notes then sit at other chunk numbers. The run being read or offered is found again by its
    /// notes' labels in the plan now in force, so what was offered or requested is still what the player is asked about.
    /// A note the new plan does not carry is dropped, and its card with it.
    private mutating func rebaseRuns(onto tags: [Tag?]) {
        if let run = hearing { hearing = Self.rebased(run, onto: tags) }
        if let run = offered { offered = Self.rebased(run, onto: tags) }
        if hearing == nil, card.isReading { clearCard() }
        if offered == nil, hearing == nil, card != .hidden { clearCard() }
    }

    private static func rebased(_ run: Run, onto tags: [Tag?]) -> Run? {
        guard let index = tags.firstIndex(where: { $0 == .aside(run.firstLabel) }) else { return nil }
        return Self.run(containing: index, tags: tags)
    }

    private mutating func clearCard() {
        offered = nil
        offeredLabel = nil
        card = .hidden
        shownAt = nil
    }

    // MARK: - Runs

    /// The asides at the citation that includes `index`: the contiguous aside chunks around it. Nil when `index` is not
    /// an aside.
    public static func run(containing index: Int, tags: [Tag?]) -> Run? {
        guard FootnoteNoteControls.isAside(at: index, tags: tags) else { return nil }
        var lower = index
        while lower > 0, FootnoteNoteControls.isAside(at: lower - 1, tags: tags) { lower -= 1 }
        var upper = index + 1
        while upper < tags.count, FootnoteNoteControls.isAside(at: upper, tags: tags) { upper += 1 }
        var labels: [String] = []
        for case .aside(let label)? in tags[lower..<upper] where !labels.contains(label) { labels.append(label) }
        return Run(chunks: lower..<upper, labels: labels)
    }

    private static func label(of index: Int, tags: [Tag?]) -> String? {
        guard tags.indices.contains(index), case .aside(let label)? = tags[index] else { return nil }
        return label
    }
}

extension FootnoteChimeSequencer.Card {
    var isReading: Bool {
        if case .reading = self { return true }
        return false
    }
}
