import Foundation
import XCTest
@testable import SessionKit

/// #3777: the media player's footnote session for an item playing its prepared audio as one file, and the two driver
/// rules the player's real seeks need (a landing just short of the target, and a listener's jump). The timelines are
/// built with `AssembledNarrationTimeline`, as `SupertonicPreparedAudioAssembler.writePCM` builds them, with a fixed
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
        let article = Item(id: item, title: "T", mediaType: "article", text: text, externalReference: nil, status: "ready")
        let projection = PreparedSpeechText(item: article, document: nil)!.assemblyProjection(asides: true)
        let ordered = plan.enumerated()
            .filter { if case .definition? = $0.element.footnote { return false } else { return true } }
            .sorted { ($0.element.startOffset, $0.offset) < ($1.element.startOffset, $1.offset) }
            .map(\.element)
        var timeline = AssembledNarrationTimeline(projection: projection, sourceText: text)
        var cursor = 0
        for chunk in ordered {
            let start = cursor
            cursor += 1_000
            timeline.append(startOffset: chunk.startOffset, sourceLength: chunk.sourceLength, text: chunk.text,
                            startMs: start, endMs: cursor)
            cursor += silenceMs
        }
        return TranscriptTimeline(segments: timeline.segments, chapters: [], durationMs: cursor)
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

extension FootnoteMediaChimeSessionTests {
    func testAClockReportThatMissesOneShortSegmentKeepsTheOffer() throws {
        // The tick is twice a second and slower under load: a report can step over one short segment without any move.
        // The sentence after note 1 is cut into three short pieces, as a PDF's skipped text cuts a chunk.
        let base = timeline(article, silenceMs: 800)
        let first = try XCTUnwrap(base.segments.firstIndex { $0.startChar != nil && $0.startChar == $0.endChar })
        let after = base.segments[first + 1]
        let third = (after.endMs - after.startMs) / 3
        let pieces = (0..<3).map { part in
            MediaTimelineSegment(id: "\(after.id)-\(part)", startMs: after.startMs + part * third,
                                 endMs: part == 2 ? after.endMs : after.startMs + (part + 1) * third,
                                 startChar: after.startChar, endChar: after.endChar, text: "piece \(part)")
        }
        var segments = base.segments
        segments.replaceSubrange((first + 1)...(first + 1), with: pieces)
        var session = try XCTUnwrap(Session(
            itemId: item, mediaKey: file,
            timeline: TranscriptTimeline(segments: segments, chapters: [], durationMs: base.durationMs), articleText: article))
        let starts = session.driver.segmentStartsMs
        _ = session.observe(timeMs: starts[first - 1], mode: .chime, appIsActive: true, now: 0)
        guard case .cue(let label, let landing) = session.observe(timeMs: starts[first], mode: .chime, appIsActive: true, now: 0) else {
            return XCTFail("cued")
        }
        XCTAssertEqual(label, "1")
        _ = session.observe(timeMs: landing, mode: .chime, appIsActive: true, now: 0)
        _ = session.observe(timeMs: starts[first + 1], mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(session.observe(timeMs: starts[first + 3], mode: .chime, appIsActive: true, now: 1), .none, "piece 1 missed")
        XCTAssertEqual(session.cardState(mode: .chime), .offered(label: "1"))
        // A real skip back still drops it.
        _ = session.observe(timeMs: 0, mode: .chime, appIsActive: true, now: 2)
        XCTAssertEqual(session.cardState(mode: .chime), .hidden)
    }
}

extension FootnoteMediaChimeSessionTests {
    /// Audit of 81a3936: the citing sentence of note 2 is cut into two short pieces (as a PDF's skipped text cuts a
    /// chunk), the last tick is in the first piece, and the next report is at the note: the second piece was missed.
    private func reachNote2(_ session: inout FootnoteMediaChimeSession) throws -> Int {
        let base = timeline(article, silenceMs: 800)
        let note = try XCTUnwrap(base.segments.indices.filter { base.segments[$0].startChar != nil
            && base.segments[$0].startChar == base.segments[$0].endChar }.dropFirst().first)
        let citing = base.segments[note - 1]
        let half = (citing.endMs - citing.startMs) / 2
        var segments = base.segments
        segments.replaceSubrange((note - 1)...(note - 1), with: [
            MediaTimelineSegment(id: "\(citing.id)-a", startMs: citing.startMs, endMs: citing.startMs + half,
                                 startChar: citing.startChar, endChar: citing.endChar, text: "piece a"),
            MediaTimelineSegment(id: "\(citing.id)-b", startMs: citing.startMs + half, endMs: citing.endMs,
                                 startChar: citing.startChar, endChar: citing.endChar, text: "piece b"),
        ])
        session = try XCTUnwrap(FootnoteMediaChimeSession(
            itemId: item, mediaKey: file,
            timeline: TranscriptTimeline(segments: segments, chapters: [], durationMs: base.durationMs), articleText: article))
        let index = try XCTUnwrap(session.driver.tags.firstIndex(of: .aside("2")))
        _ = session.observe(timeMs: session.driver.segmentStartsMs[index - 2], mode: .chime, appIsActive: true, now: 0)
        return index
    }

    func testATickThatMissedTheCitingSegmentStillCuesTheNote() throws {
        var session = try makeSession()
        let note = try reachNote2(&session)
        guard case .cue(let label, _) = session.observe(
            timeMs: session.driver.segmentStartsMs[note] + 100, mode: .chime, appIsActive: true, now: 0) else {
            return XCTFail("cued, not passed over silently")
        }
        XCTAssertEqual(label, "2")
    }

    func testABoundaryReportCuesTheNoteWhateverTheLastTickSaw() throws {
        var session = try makeSession()
        _ = session.observe(timeMs: 0, mode: .chime, appIsActive: true, now: 0)
        let note = try XCTUnwrap(session.driver.tags.firstIndex(of: .aside("2")))
        XCTAssertGreaterThan(note, 2, "the last tick is well before the note")
        guard case .cue(let label, _) = session.observeBoundary(
            timeMs: session.driver.segmentStartsMs[note] - 10, mode: .chime, appIsActive: true, now: 0) else {
            return XCTFail("cued")
        }
        XCTAssertEqual(label, "2")
    }

    func testTheLeadInOfAMultiNoteCitationShowsTheOfferedNote() throws {
        var session = try makeSession()
        let note = try XCTUnwrap(session.driver.tags.firstIndex(of: .aside("2")))
        XCTAssertEqual(session.driver.tags[note + 1], .aside("3"))
        _ = session.observe(timeMs: session.driver.segmentStartsMs[note - 1], mode: .chime, appIsActive: true, now: 0)
        guard case .cue(_, let landing) = session.observe(
            timeMs: session.driver.segmentStartsMs[note], mode: .chime, appIsActive: true, now: 0) else {
            return XCTFail("cued")
        }
        XCTAssertEqual(session.driver.segmentIndex(atMs: landing), note + 1, "the landing is in note 3's silence")
        _ = session.observe(timeMs: landing, mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(session.card(atMs: landing, mode: .chime)?.label, "2")
    }
}
