import Foundation
import XCTest
@testable import SessionKit

/// #3777: the media player's footnote session for an item playing its prepared audio as one file, and the two driver
/// rules the player's real seeks need (a landing just short of the target, and a listener's jump). The timelines are
/// built as `SupertonicPreparedAudioAssembler.writePCM` builds them (see `FootnoteMediaChimeDriverTests`), with a fixed
/// silence after each chunk so the tone's lead-in can be measured.
final class FootnoteMediaChimeSessionTests: XCTestCase {
    private typealias Session = FootnoteMediaChimeSession

    private let item = "item-1"
    private let file = "file:///prepared/item-1-abc.m4a"
    private let article = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2][^3] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    [^3]: Park, Ports, 2022.
    """

    private func timeline(_ text: String, silenceMs: Int) -> TranscriptTimeline {
        let plan = NarrationChunkPlanner.articlePlan(text, asides: true).chunks
        let projection = NarrationChunkPlanner.silencedSpeech(source: text, endingWith: text)
            ?? SpeechTextNormalizer.normalizeWithSourceOffsets(text)
        let source = Array(text)
        let ordered = plan.enumerated()
            .filter { if case .definition? = $0.element.footnote { return false } else { return true } }
            .sorted { ($0.element.startOffset, $0.offset) < ($1.element.startOffset, $1.offset) }
            .map(\.element)
        var segments: [MediaTimelineSegment] = []
        var cursor = 0
        for chunk in ordered {
            let start = cursor
            cursor += 1_000
            let pieces = NarrationTimelinePieces.pieces(
                spokenRange: chunk.startOffset..<(chunk.startOffset + chunk.sourceLength),
                startMs: start, endMs: cursor, projection: projection, source: source)
            for piece in pieces {
                segments.append(MediaTimelineSegment(
                    id: "seg-\(segments.count)", startMs: piece.startMs, endMs: piece.endMs,
                    startChar: piece.startChar, endChar: piece.endChar,
                    text: pieces.count == 1 ? chunk.text : "piece"))
            }
            cursor += silenceMs
        }
        return TranscriptTimeline(segments: segments, chapters: [], durationMs: cursor)
    }

    private func makeSession(silenceMs: Int = 800) throws -> Session {
        try XCTUnwrap(Session(itemId: item, mediaKey: file, timeline: timeline(article, silenceMs: silenceMs), articleText: article))
    }

    private func start(_ session: Session, _ label: String) throws -> (index: Int, ms: Int) {
        let index = try XCTUnwrap(session.driver.tags.firstIndex(of: .aside(label)))
        return (index, session.driver.segmentStartsMs[index])
    }

    // MARK: - Which file

    func testItAnswersOnlyForItsOwnItemAndFile() throws {
        let session = try makeSession()
        XCTAssertTrue(session.plays(itemId: item, mediaKey: file))
        XCTAssertFalse(session.plays(itemId: "item-2", mediaKey: file))
        XCTAssertFalse(session.plays(itemId: item, mediaKey: "file:///prepared/item-1-new.m4a"), "a file prepared again")
    }

    func testAnArticleWithoutNotesOrAFileWithoutAsidesHasNoSession() {
        let plain = "Nothing to cite here. Only plain sentences follow."
        XCTAssertNil(Session(itemId: item, mediaKey: file, timeline: timeline(plain, silenceMs: 500), articleText: plain))
        // The plain plan's timeline holds no aside segment: a file prepared with the notes at the end.
        let plainPlan = NarrationChunkPlanner.articlePlan(article, asides: false).chunks
        let segments = plainPlan.enumerated().map { index, chunk in
            MediaTimelineSegment(id: "s\(index)", startMs: index * 1_000, endMs: index * 1_000 + 900,
                                 startChar: chunk.startOffset, endChar: chunk.startOffset + chunk.sourceLength, text: chunk.text)
        }
        XCTAssertNil(Session(itemId: item, mediaKey: file, timeline: TranscriptTimeline(segments: segments, chapters: []), articleText: article))
    }

    // MARK: - The tone's lead-in

    func testACueLandsTheLeadInBeforeTheNextSentenceInTheNotesSilence() throws {
        var session = try makeSession(silenceMs: 800)
        let note = try start(session, "1")
        let next = session.driver.segmentStartsMs[note.index + 1]
        _ = session.observe(timeMs: session.driver.segmentStartsMs[note.index - 1], mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(session.observe(timeMs: note.ms, mode: .chime, appIsActive: true, now: 0),
                       .cue(label: "1", seekToMs: next - Int(FootnoteCue.leadIn * 1_000)))
    }

    func testWithLittleSilenceTheCueLandsPastTheNotesWordsOrAtTheNextSentence() throws {
        // 500 ms of silence: 0.4 s before the next sentence is inside the player's tolerance of the note's words, so
        // the landing moves later, to a quarter second past them.
        var session = try makeSession(silenceMs: 500)
        let note = try start(session, "1")
        let noteEnd = note.ms + 1_000
        _ = session.observe(timeMs: session.driver.segmentStartsMs[note.index - 1], mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(session.observe(timeMs: note.ms, mode: .chime, appIsActive: true, now: 0),
                       .cue(label: "1", seekToMs: noteEnd + Session.seekToleranceMs))

        // No silence at all: the move goes to the next sentence's start.
        var tight = try makeSession(silenceMs: 0)
        let tightNote = try start(tight, "1")
        _ = tight.observe(timeMs: tight.driver.segmentStartsMs[tightNote.index - 1], mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(tight.observe(timeMs: tightNote.ms, mode: .chime, appIsActive: true, now: 0),
                       .cue(label: "1", seekToMs: tight.driver.segmentStartsMs[tightNote.index + 1]))
    }

    func testACueLandingInTheNotesSilenceRunsOnWithoutCountingTheNoteHeardOrCueingAgain() throws {
        var session = try makeSession(silenceMs: 800)
        let note = try start(session, "1")
        let next = session.driver.segmentStartsMs[note.index + 1]
        _ = session.observe(timeMs: session.driver.segmentStartsMs[note.index - 1], mode: .chime, appIsActive: true, now: 0)
        guard case .cue(_, let landing) = session.observe(timeMs: note.ms, mode: .chime, appIsActive: true, now: 0) else {
            return XCTFail("cued")
        }
        XCTAssertEqual(session.observe(timeMs: landing, mode: .chime, appIsActive: true, now: 0), .none)
        XCTAssertEqual(session.observe(timeMs: next, mode: .chime, appIsActive: true, now: 0), .none)
        XCTAssertEqual(session.cardState(mode: .chime), .offered(label: "1"), "the offer stands after the move")
        XCTAssertFalse(session.driver.heard.hasHeardNote("1", itemId: item))
    }

    // MARK: - Boundary reports

    func testABoundaryReportJustShortOfTheRunStartCuesTheNote() throws {
        var session = try makeSession()
        let note = try start(session, "1")
        _ = session.observe(timeMs: session.driver.segmentStartsMs[note.index - 1], mode: .chime, appIsActive: true, now: 0)
        // The plain clock read 20 ms short is still the sentence before.
        var plain = session
        XCTAssertEqual(plain.observe(timeMs: note.ms - 20, mode: .chime, appIsActive: true, now: 0), .none)
        guard case .cue(let label, _) = session.observeBoundary(timeMs: note.ms - 20, mode: .chime, appIsActive: true, now: 0) else {
            return XCTFail("the boundary report cues the note")
        }
        XCTAssertEqual(label, "1")
    }

    func testABoundaryReportFarFromAnyRunIsAPlainReport() throws {
        var session = try makeSession()
        let note = try start(session, "1")
        let earlier = session.driver.segmentStartsMs[note.index - 1]
        XCTAssertEqual(session.observeBoundary(timeMs: earlier, mode: .chime, appIsActive: true, now: 0), .none)
    }

    // MARK: - The card

    func testTheCardShowsTheNoteWhoseWordsPlayAndTheOfferedNoteInChime() throws {
        var session = try makeSession()
        let note = try start(session, "1")
        let before = session.driver.segmentStartsMs[note.index - 1]
        XCTAssertNil(session.card(atMs: before, mode: .whereCited))
        XCTAssertEqual(session.card(atMs: note.ms + 10, mode: .whereCited), FootnoteCard(label: "1", body: "Smith, Tides, 2020."))

        _ = session.observe(timeMs: before, mode: .chime, appIsActive: true, now: 0)
        _ = session.observe(timeMs: note.ms, mode: .chime, appIsActive: true, now: 0)
        let after = session.driver.segmentStartsMs[note.index + 1]
        XCTAssertEqual(session.card(atMs: after, mode: .chime)?.label, "1", "the offered note, over the next sentence")
        XCTAssertNil(session.card(atMs: after, mode: .whereCited), "a choice changed since offers nothing")
        XCTAssertEqual(session.cardState(mode: .chime), .offered(label: "1"))
        XCTAssertEqual(session.cardState(mode: .whereCited), .hidden)
    }

    // MARK: - Driver rules for real seeks

    func testHearNoteLandingJustShortOfTheNoteStillReadsIt() throws {
        // The player lands up to a quarter second early: in the silence after the citing sentence.
        var session = try makeSession()
        let note = try start(session, "1")
        _ = session.observe(timeMs: session.driver.segmentStartsMs[note.index - 1], mode: .chime, appIsActive: true, now: 0)
        _ = session.observe(timeMs: note.ms, mode: .chime, appIsActive: true, now: 0)
        let after = session.driver.segmentStartsMs[note.index + 1]
        _ = session.observe(timeMs: after, mode: .chime, appIsActive: true, now: 1)

        XCTAssertEqual(session.hearOfferedNote(), note.ms)
        XCTAssertEqual(session.observe(timeMs: note.ms - 200, mode: .chime, appIsActive: true, now: 2), .none)
        XCTAssertEqual(session.cardState(mode: .chime), .reading(label: "1"), "still the listener's request")
        XCTAssertEqual(session.observe(timeMs: note.ms, mode: .chime, appIsActive: true, now: 2), .none, "read, not cued")
        XCTAssertEqual(session.observe(timeMs: after, mode: .chime, appIsActive: true, now: 3), .none)
        XCTAssertTrue(session.driver.heard.hasHeardNote("1", itemId: item))
    }

    func testAListenersJumpElsewhereDropsAnOfferedOrReadNote() throws {
        var session = try makeSession()
        let note = try start(session, "1")
        _ = session.observe(timeMs: session.driver.segmentStartsMs[note.index - 1], mode: .chime, appIsActive: true, now: 0)
        _ = session.observe(timeMs: note.ms, mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(session.cardState(mode: .chime), .offered(label: "1"))
        // A skip of half a minute back: not the segment after, not the driver's own move.
        XCTAssertEqual(session.observe(timeMs: 0, mode: .chime, appIsActive: true, now: 1), .none)
        XCTAssertEqual(session.cardState(mode: .chime), .hidden)

        // The same while the listener hears a note.
        _ = session.hearNote(label: "2")
        let second = try start(session, "2")
        _ = session.observe(timeMs: second.ms, mode: .chime, appIsActive: true, now: 2)
        XCTAssertEqual(session.cardState(mode: .chime), .reading(label: "2"))
        _ = session.observe(timeMs: 0, mode: .chime, appIsActive: true, now: 3)
        XCTAssertEqual(session.cardState(mode: .chime), .hidden)
    }

    func testPlayingThroughStillCuesEachCitationOnce() throws {
        // The full walk with the lead-in landings: one tone per citing sentence and no note read.
        var session = try makeSession()
        var cues: [String] = []
        var fromStart: [Int] = []
        var time = 0
        var steps = 0
        while time < session.driver.durationMs, steps < 200 {
            steps += 1
            let index = session.driver.segmentIndex(atMs: time)
            switch session.observe(timeMs: time, mode: .chime, appIsActive: true, now: 0) {
            case .none:
                // A lead-in landing joins a note's silence, not its words: only a segment played from its start is heard.
                if time == session.driver.segmentStartsMs[index] { fromStart.append(index) }
                time = index + 1 < session.driver.segmentStartsMs.count ? session.driver.segmentStartsMs[index + 1] : session.driver.durationMs
            case .seek(let ms):
                time = ms
            case .cue(let label, let ms):
                cues.append(label)
                time = ms
            }
        }
        XCTAssertEqual(cues, ["1", "2"])
        XCTAssertEqual(fromStart.filter { FootnoteNoteControls.isAside(at: $0, tags: session.driver.tags) }, [], "no note's words play")
        let body = session.driver.tags.indices.filter { session.driver.tags[$0] == nil }
        XCTAssertEqual(body.filter { !fromStart.contains($0) }, [], "no body segment is dropped")
    }
}
