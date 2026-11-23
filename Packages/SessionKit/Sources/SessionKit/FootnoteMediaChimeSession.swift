import Foundation

/// The footnotes of the item playing its prepared audio as one file (#3777): the app's media player holds one of these
/// for that item and file, reports its clock to it, and shows the Footnote card from it. It wraps
/// `FootnoteMediaChimeDriver` with what the player needs beyond the driver's rules:
///
/// 1. Which item and file it was made for (`plays(itemId:mediaKey:)`), so a session left from another item or an older
///    file is never asked.
/// 2. The tone's lead-in. On the on-device voice the text after a cued note waits `FootnoteCue.leadIn` behind the tone.
///    A file can't wait, so a cue's move lands that much before the next segment, in the silence the file already has
///    after the note, never earlier than a quarter second past the note's own words (the player may land that far
///    early). With less silence than that, the move goes to the next segment's start and the tone overlaps it.
/// 3. The card's words: each segment's own text, so the card shows the whole note as the on-device voice's card does.
/// 4. A boundary report (`observeBoundary`): the player's clock can read a hair before the time a boundary observer
///    fired at, which would be the segment before the note. A report within `boundarySnapMs` of a run's start is read
///    as that start.
public struct FootnoteMediaChimeSession: Equatable, Sendable {
    public let itemId: String
    /// The file's identity, its URL: a new file for the same item (prepared again) needs a new session.
    public let mediaKey: String
    public private(set) var driver: FootnoteMediaChimeDriver
    private let texts: [String]
    private let segmentEndsMs: [Int]

    /// How close a boundary report must be to a run's start to count as it.
    public static let boundarySnapMs = 300
    /// How far a seek may land from the time asked for (`requestMediaSeek` asks for a quarter second either way).
    public static let seekToleranceMs = 250

    /// Nil when the file reads no note where it is cited, or was not made from `plan` (see the driver's `init`).
    public init?(itemId: String, mediaKey: String, timeline: TranscriptTimeline, plan: [NarrationChunkPlanner.Chunk]) {
        guard let driver = FootnoteMediaChimeDriver(itemId: itemId, timeline: timeline, plan: plan) else { return nil }
        self.itemId = itemId
        self.mediaKey = mediaKey
        self.driver = driver
        self.texts = timeline.segments.map(\.text)
        self.segmentEndsMs = timeline.segments.map(\.endMs)
    }

    /// Built from the text the file was made from: the plan with note chunks (`articlePlan(_:asides: true)`), which is
    /// the plan of every file prepared while notes were read where cited. A file prepared with the notes at the end
    /// holds no aside segment, so this is nil for it.
    public init?(itemId: String, mediaKey: String, timeline: TranscriptTimeline, articleText: String) {
        self.init(itemId: itemId, mediaKey: mediaKey, timeline: timeline,
                  plan: NarrationChunkPlanner.articlePlan(articleText, asides: true).chunks)
    }

    public func plays(itemId: String, mediaKey: String) -> Bool {
        self.itemId == itemId && self.mediaKey == mediaKey
    }

    /// Where a boundary observer should fire: the start of every run of notes.
    public var runStartsMs: [Int] { driver.runStartsMs }

    /// The player's clock (the playback tick, twice a second). See `FootnoteMediaChimeDriver.observe`.
    public mutating func observe(
        timeMs: Int, mode: FootnoteMode, appIsActive: Bool, now: TimeInterval
    ) -> FootnoteMediaChimeDriver.Action {
        report(timeMs: timeMs, mode: mode, appIsActive: appIsActive, now: now, reachedByPlayback: false)
    }

    private mutating func report(
        timeMs: Int, mode: FootnoteMode, appIsActive: Bool, now: TimeInterval, reachedByPlayback: Bool
    ) -> FootnoteMediaChimeDriver.Action {
        let action = driver.observe(
            timeMs: timeMs, mode: mode, appIsActive: appIsActive, now: now, reachedByPlayback: reachedByPlayback)
        guard case .cue(let label, let seekToMs) = action else { return action }
        return .cue(label: label, seekToMs: leadInLanding(before: seekToMs))
    }

    /// A boundary observer fired at a run's start. `timeMs` is the player's clock when the report was read. A boundary
    /// fires only while the file plays on, so the note may cue whatever segment the last tick saw.
    public mutating func observeBoundary(
        timeMs: Int, mode: FootnoteMode, appIsActive: Bool, now: TimeInterval
    ) -> FootnoteMediaChimeDriver.Action {
        let snapped = runStartsMs.first { abs($0 - timeMs) <= Self.boundarySnapMs }.map { max($0, timeMs) } ?? timeMs
        return report(timeMs: snapped, mode: mode, appIsActive: appIsActive, now: now, reachedByPlayback: true)
    }

    /// Where a cue's move lands: `FootnoteCue.leadIn` before `targetMs` when the silence after the note holds it.
    private func leadInLanding(before targetMs: Int) -> Int {
        guard let target = driver.segmentStartsMs.firstIndex(of: targetMs), target > 0 else { return targetMs }
        let leadIn = Int((FootnoteCue.leadIn * 1_000).rounded())
        let earliest = segmentEndsMs[target - 1] + Self.seekToleranceMs
        return min(targetMs, max(earliest, targetMs - leadIn))
    }

    /// The card for the place `timeMs`: the note whose words play there, or in "Chime where cited" the note the tone
    /// offered or the listener is hearing. Nil elsewhere, and for a note with nothing left once its lead is removed.
    public func card(atMs timeMs: Int, mode: FootnoteMode) -> FootnoteCard? {
        let tags = driver.tags
        // The note the tone offered comes first: a cue's lead-in landing is in the silence of its run's last note, which
        // for "[^2][^3]" is note 3 while the card offers note 2. A note being read shows the note whose words play.
        if mode == .chime, case .offered(let label) = driver.sequencer.card,
           let note = tags.firstIndex(where: { $0 == .aside(label) }) {
            return FootnoteCard.forChunk(at: note, tags: tags, texts: texts)
        }
        let index = driver.segmentIndex(atMs: timeMs)
        if FootnoteNoteControls.isAside(at: index, tags: tags) {
            return FootnoteCard.forChunk(at: index, tags: tags, texts: texts)
        }
        guard mode == .chime, let label = driver.sequencer.card.label,
              let note = tags.firstIndex(where: { $0 == .aside(label) }) else { return nil }
        return FootnoteCard.forChunk(at: note, tags: tags, texts: texts)
    }

    /// The card's button state: `hidden` in any mode but "Chime where cited".
    public func cardState(mode: FootnoteMode) -> FootnoteChimeSequencer.Card {
        mode == .chime ? driver.sequencer.card : .hidden
    }

    public mutating func hearOfferedNote() -> Int? { driver.hearOfferedNote() }
    public mutating func stopHearing() -> Int? { driver.stopHearing() }
    public mutating func hearNote(label: String) -> Int? { driver.hearNote(label: label) }
    public mutating func playerMovedOnItsOwn() { driver.playerMovedOnItsOwn() }
    public mutating func playedToEnd() { driver.playedToEnd() }

    @discardableResult
    public mutating func expireCard(now: TimeInterval, voiceOverIsOnCard: Bool) -> Bool {
        driver.expireCard(now: now, voiceOverIsOnCard: voiceOverIsOnCard)
    }
}
