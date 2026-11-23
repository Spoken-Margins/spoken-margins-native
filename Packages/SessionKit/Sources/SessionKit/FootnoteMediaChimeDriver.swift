import Foundation

/// "Chime where cited" for an item that plays its prepared audio as one file (#3777). Once every chunk of an article is
/// prepared, the app assembles them into one audio file and plays that file as media (`generatedTTSPrerendered`), not
/// through the on-device voice. The file was made from the plan with note chunks, which `whereCited` and `chime` share
/// (Design, Defaults taken 9), so it reads every note where it is cited. Before this type, the chime mode did nothing on
/// that path: the notes were read in full, with no tone and no card.
///
/// This type gives the media player the same `FootnoteChimeSequencer` the on-device voice uses, by treating each segment
/// of the file's timeline as a chunk. The player reports its clock (`observe`); the answer says to do nothing, to seek
/// past a note silently, or to cue it (one tone, the card) and seek past it. Hear note, Stop note and a Timeline tap
/// answer with a time to seek to.
///
/// Two rules differ from the on-device voice, because a file is not a plan:
/// 1. The file leaves out the notes chapter's copies of the notes (`PreparedAudioCoordinator.assemblyChunks`), so a note
///    passed over is not read at the end. While the app is not active, where the on-device voice passes over a note
///    silently and reads it in the notes chapter, the file reads the note where it is cited instead, so nothing is lost
///    while the listener cannot tap.
/// 2. Only playback that runs on into a note's segment can cue it. A start, a seek or a resume that lands in a note
///    passes over it silently, as a play that begins inside a run does on the on-device voice.
///
/// Nothing calls this yet: the media player's wiring and the card on that path are the visible half.
public struct FootnoteMediaChimeDriver: Equatable, Sendable {
    public typealias Tag = NarrationChunkPlanner.FootnoteTag

    /// What the media player does after reporting its clock.
    public enum Action: Equatable, Sendable {
        /// Keep playing.
        case none
        /// Move to `ms` without a sound: the note was heard already, or playback started inside it.
        case seek(toMs: Int)
        /// Play the tone, raise the card for `label`, and move to `ms`, the sentence after the citation.
        case cue(label: String, seekToMs: Int)
    }

    /// Each timeline segment's footnote tag: `.aside(label)` for a segment that reads a note, nil for the rest.
    public let tags: [Tag?]
    /// Each segment's start in the file, in milliseconds, in the timeline's order.
    public let segmentStartsMs: [Int]
    /// The file's end: where a move past a note that ends the text goes.
    public let durationMs: Int
    /// The notes heard to their end in this file, so a note read already is not offered again.
    public private(set) var heard = FootnoteHeardSet()
    public private(set) var sequencer = FootnoteChimeSequencer()

    private let itemId: String
    /// The segment the last `observe` was in. nil before the first report and after a move the driver did not make.
    private var current: Int?
    /// The segment a move the driver made lands in: reaching it counts as running on, not as a seek.
    private var expectedEntry: Int?
    /// Whether `current` was entered at its start (run on into, or a move the driver made), so playing it to its end
    /// counts as hearing it. A start, a seek or a resume that lands inside a note never counts.
    private var currentEnteredAtStart = false

    /// Nil when the file holds no note chunk, or when a note chunk of `plan` has no segment of its own in `timeline`
    /// (the file was made from another plan): the player then plays the file as it is, which is today's behaviour.
    ///
    /// - `timeline`: the assembled file's timeline, its segments in file order.
    /// - `plan`: the chunks of `NarrationChunkPlanner.articlePlan(_:asides: true)` for the text the file was made from.
    public init?(itemId: String, timeline: TranscriptTimeline, plan: [NarrationChunkPlanner.Chunk]) {
        // The file holds the plan's chunks without the notes chapter's copies, ordered by where each starts (an aside
        // starts where the sentence after its citation does and stays in front of it), as `SupertonicPreparedAudioAssembler`
        // orders them. An aside is never split: it reads no source characters, so it has one segment, with an empty
        // character range and the chunk's own words.
        let asides = plan.enumerated()
            .filter { if case .definition? = $0.element.footnote { return false } else { return true } }
            .sorted { ($0.element.startOffset, $0.offset) < ($1.element.startOffset, $1.offset) }
            .map(\.element)
            .filter { if case .aside? = $0.footnote { return true } else { return false } }
        guard !asides.isEmpty, !timeline.segments.isEmpty else { return nil }
        var tags = [Tag?](repeating: nil, count: timeline.segments.count)
        var searchFrom = 0
        for chunk in asides {
            guard let found = timeline.segments[searchFrom...].firstIndex(where: { Self.isAside($0, of: chunk) }) else {
                return nil
            }
            tags[found] = chunk.footnote
            searchFrom = found + 1
        }
        self.itemId = itemId
        self.tags = tags
        self.segmentStartsMs = timeline.segments.map(\.startMs)
        self.durationMs = max(timeline.durationMs ?? 0, timeline.segments.map(\.endMs).max() ?? 0)
    }

    private static func isAside(_ segment: MediaTimelineSegment, of chunk: NarrationChunkPlanner.Chunk) -> Bool {
        guard let start = segment.startChar, let end = segment.endChar, start == end else { return false }
        return segment.text == chunk.text
    }

    /// The start of every run of notes, in milliseconds, so the player can stop at each exactly (a boundary observer)
    /// instead of letting a periodic clock run a little of the note before it moves.
    public var runStartsMs: [Int] {
        tags.indices.filter { index in
            FootnoteNoteControls.isAside(at: index, tags: tags) && !FootnoteNoteControls.isAside(at: index - 1, tags: tags)
        }.map { segmentStartsMs[$0] }
    }

    /// The segment that plays at `ms`: the last one that starts at or before it. The silence after a segment belongs
    /// to it, and a time before the first segment is the first.
    public func segmentIndex(atMs ms: Int) -> Int {
        var low = 0
        var high = segmentStartsMs.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segmentStartsMs[mid] <= ms { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The player's clock, at least as often as a segment changes (and at each of `runStartsMs`).
    public mutating func observe(
        timeMs: Int, mode: FootnoteMode, appIsActive: Bool, now: TimeInterval
    ) -> Action {
        let index = segmentIndex(atMs: timeMs)
        guard index != current else { return .none }
        let ranOn = current.map { index == $0 + 1 } ?? false
        let landedFromOwnMove = index == expectedEntry
        // A move the driver made past a note can land on the very next segment; that note was passed over, not heard.
        if ranOn, !landedFromOwnMove { recordCurrentPlayedToEnd() }
        let runOn = ranOn || landedFromOwnMove
        expectedEntry = nil
        current = index
        currentEnteredAtStart = runOn
        // Rule 1: with the app not active the note is read where it is cited. The sequencer is not asked, so a card
        // or a request it holds waits for the listener's return.
        guard appIsActive else { return .none }
        // Rule 2: only running on into a note may cue it; the sequencer passes over it silently when told the app is
        // not active, and that is the only thing the flag changes there.
        let step = sequencer.willStartChunk(
            at: index, tags: tags, itemId: itemId, mode: mode, appIsActive: runOn, heard: heard, now: now)
        switch step {
        case .play:
            return .none
        case .skip(let continueAt):
            return .seek(toMs: move(to: continueAt))
        case .cue(_, let continueAt):
            let label = sequencer.card.label ?? ""
            return .cue(label: label, seekToMs: move(to: continueAt))
        }
    }

    /// The card's Hear note: where to move to read the offered run, its first note's start. Nil when nothing is offered.
    public mutating func hearOfferedNote() -> Int? {
        guard let first = sequencer.hearOfferedNote(tags: tags) else { return nil }
        return move(to: first)
    }

    /// The card's Stop note: where to move to go on with the text after the note. Nil when no note is being read.
    public mutating func stopHearing() -> Int? {
        guard let resume = sequencer.stopHearing(tags: tags, itemId: itemId, heard: heard) else { return nil }
        return move(to: resume.continueAt)
    }

    /// A Timeline entry for the note `label`: where to move to read it, the start of its run. A file can start
    /// anywhere, so unlike the on-device voice this needs no request held for a later plan. Nil when the file does not
    /// read that note.
    public mutating func hearNote(label: String) -> Int? {
        guard let note = tags.firstIndex(where: { $0 == .aside(label) }),
              let first = sequencer.beginHearing(chunkAt: note, tags: tags) else { return nil }
        return move(to: first)
    }

    /// A move the driver did not make (the listener's seek, a skip button, another item) or a stop: nothing is offered,
    /// and the next report is a fresh start.
    public mutating func playerMovedOnItsOwn() {
        sequencer.reset()
        current = nil
        expectedEntry = nil
        currentEnteredAtStart = false
    }

    /// The file played to its end. The last segment counts as heard if it was entered at its start, and the card goes,
    /// as the sequencer's end-of-text call does on the on-device voice.
    public mutating func playedToEnd() {
        recordCurrentPlayedToEnd()
        _ = sequencer.willStartChunk(
            at: tags.count, tags: tags, itemId: itemId, mode: .chime, appIsActive: false, heard: heard, now: 0)
        current = nil
        expectedEntry = nil
        currentEnteredAtStart = false
    }

    private mutating func recordCurrentPlayedToEnd() {
        guard let current, currentEnteredAtStart else { return }
        heard.recordPlayedToEnd(chunkAt: current, tags: tags, itemId: itemId)
    }

    /// The card's 30 seconds after the tone (`FootnoteChimeSequencer.expireCard`).
    @discardableResult
    public mutating func expireCard(now: TimeInterval, voiceOverIsOnCard: Bool) -> Bool {
        sequencer.expireCard(now: now, voiceOverIsOnCard: voiceOverIsOnCard)
    }

    private mutating func move(to segment: Int?) -> Int {
        guard let segment, segmentStartsMs.indices.contains(segment) else {
            expectedEntry = nil
            return durationMs
        }
        expectedEntry = segment
        // A move to the segment playing now (Hear note before the clock left the note) must still be seen landing.
        if segment == current { current = nil }
        return segmentStartsMs[segment]
    }
}
