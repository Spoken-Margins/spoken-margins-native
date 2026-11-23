import Foundation
import XCTest
@testable import SessionKit

/// #3777: "Chime where cited" on an item that plays its assembled prepared audio as one file. The timelines here are
/// built the way `SupertonicPreparedAudioAssembler.writePCM` builds them: the plan with note chunks, without the notes
/// chapter's copies, ordered by start, each chunk split by the real `NarrationTimelinePieces`, a second of audio each
/// and its boundary's silence after it.
final class FootnoteMediaChimeDriverTests: XCTestCase {
    private typealias Driver = FootnoteMediaChimeDriver

    private let item = "item-1"
    private let article = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2][^3] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    [^3]: Park, Ports, 2022.
    """

    private struct File {
        let timeline: TranscriptTimeline
        let plan: [NarrationChunkPlanner.Chunk]
        /// Each segment's chunk, for reading what a walk played.
        let segmentChunks: [NarrationChunkPlanner.Chunk]
    }

    private func assembledFile(_ text: String) -> File {
        let plan = NarrationChunkPlanner.articlePlan(text, asides: true).chunks
        let projection = NarrationChunkPlanner.silencedSpeech(source: text, endingWith: text)
            ?? SpeechTextNormalizer.normalizeWithSourceOffsets(text)
        let source = Array(text)
        let ordered = plan.enumerated()
            .filter { if case .definition? = $0.element.footnote { return false } else { return true } }
            .sorted { ($0.element.startOffset, $0.offset) < ($1.element.startOffset, $1.offset) }
            .map(\.element)
        var segments: [MediaTimelineSegment] = []
        var owners: [NarrationChunkPlanner.Chunk] = []
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
                owners.append(chunk)
            }
            cursor += Int((chunk.boundary.transitionDelay * 1_000).rounded())
        }
        return File(timeline: TranscriptTimeline(segments: segments, chapters: [], durationMs: cursor), plan: plan, segmentChunks: owners)
    }

    private func driver(_ file: File) throws -> Driver {
        try XCTUnwrap(Driver(itemId: item, timeline: file.timeline, plan: file.plan))
    }

    /// Plays the file from `startMs` the way a player reporting its clock at every segment start would, following each
    /// move the driver asks for. Returns the segments played and the cues, in order.
    private func walk(
        _ driver: inout Driver, file: File, from startMs: Int = 0, mode: FootnoteMode = .chime, active: Bool = true
    ) -> (played: [Int], cues: [String]) {
        var played: [Int] = []
        var cues: [String] = []
        var time = startMs
        var steps = 0
        while time < driver.durationMs, steps < 1_000 {
            steps += 1
            let index = driver.segmentIndex(atMs: time)
            switch driver.observe(timeMs: time, mode: mode, appIsActive: active, now: 0) {
            case .none:
                played.append(index)
                time = index + 1 < driver.segmentStartsMs.count ? driver.segmentStartsMs[index + 1] : driver.durationMs
            case .seek(let ms):
                time = ms
            case .cue(let label, let ms):
                cues.append(label)
                time = ms
            }
        }
        XCTAssertLessThan(steps, 1_000, "the walk ends")
        return (played, cues)
    }

    private func asideLabels(_ segments: [Int], _ driver: Driver) -> [String] {
        segments.compactMap { index -> String? in
            guard case .aside(let label)? = driver.tags[index] else { return nil }
            return label
        }
    }

    // MARK: - Finding the notes in the file

    func testEveryNoteInTheFileIsFoundAtItsOwnSegment() throws {
        let file = assembledFile(article)
        let driver = try driver(file)
        XCTAssertEqual(driver.tags.count, file.timeline.segments.count)
        XCTAssertEqual(asideLabels(Array(driver.tags.indices), driver), ["1", "2", "3"])
        for (index, tag) in driver.tags.enumerated() {
            XCTAssertEqual(tag, file.segmentChunks[index].footnote, "segment \(index)")
        }
        XCTAssertEqual(driver.runStartsMs.count, 2, "one stop per citing sentence")
    }

    func testAnArticleWithoutANoteHasNoDriver() {
        let file = assembledFile("Nothing to cite here. Only plain sentences follow.")
        XCTAssertNil(Driver(itemId: item, timeline: file.timeline, plan: file.plan))
    }

    func testAFileMadeWithoutNoteChunksHasNoDriver() {
        // A file assembled under the plain identity (Design, Defaults taken 10) reads its notes at the end: nothing
        // here may skip part of it.
        let withNotes = NarrationChunkPlanner.articlePlan(article, asides: true).chunks
        let plain = NarrationChunkPlanner.articlePlan(article, asides: false).chunks
        let plainSegments = plain.enumerated().map { index, chunk in
            MediaTimelineSegment(id: "s\(index)", startMs: index * 1_000, endMs: index * 1_000 + 900,
                                 startChar: chunk.startOffset, endChar: chunk.startOffset + chunk.sourceLength, text: chunk.text)
        }
        XCTAssertNil(Driver(itemId: item, timeline: TranscriptTimeline(segments: plainSegments, chapters: []), plan: withNotes))
    }

    func testSegmentIndexCountsTheSilenceAfterASegmentAsItsOwn() throws {
        let driver = try driver(assembledFile(article))
        XCTAssertEqual(driver.segmentIndex(atMs: -5), 0)
        XCTAssertEqual(driver.segmentIndex(atMs: 0), 0)
        XCTAssertEqual(driver.segmentIndex(atMs: driver.segmentStartsMs[1] - 1), 0)
        XCTAssertEqual(driver.segmentIndex(atMs: driver.segmentStartsMs[1]), 1)
        XCTAssertEqual(driver.segmentIndex(atMs: driver.durationMs + 10), driver.segmentStartsMs.count - 1)
    }

    // MARK: - Chime where cited

    func testPlayingThroughCuesEachCitationOnceAndReadsNoNote() throws {
        let file = assembledFile(article)
        var driver = try driver(file)
        let result = walk(&driver, file: file)
        XCTAssertEqual(result.cues, ["1", "2"], "one tone per citing sentence, the card naming its first note")
        XCTAssertEqual(asideLabels(result.played, driver), [], "no note is read in the text")
        let body = driver.tags.indices.filter { driver.tags[$0] == nil }
        XCTAssertEqual(body.filter { !result.played.contains($0) }, [], "no body segment is dropped")
    }

    func testAPassedOverNoteIsNotCountedAsHeard() throws {
        let file = assembledFile(article)
        var driver = try driver(file)
        _ = walk(&driver, file: file)
        for label in ["1", "2", "3"] {
            XCTAssertFalse(driver.heard.hasHeardNote(label, itemId: item), "note \(label)")
        }
    }

    func testReadWhereCitedAndReadAtTheEndPlayTheFileAsItIs() throws {
        let file = assembledFile(article)
        for mode in [FootnoteMode.whereCited, .atEnd] {
            var driver = try driver(file)
            let result = walk(&driver, file: file, mode: mode)
            XCTAssertEqual(result.cues, [], "\(mode)")
            XCTAssertEqual(result.played, Array(driver.tags.indices), "\(mode)")
        }
    }

    func testWithTheAppNotActiveEveryNoteIsReadWhereCited() throws {
        // The file has no notes chapter copy to fall back on, so a note passed over in the background would be lost.
        let file = assembledFile(article)
        var driver = try driver(file)
        let result = walk(&driver, file: file, active: false)
        XCTAssertEqual(result.cues, [])
        XCTAssertEqual(result.played, Array(driver.tags.indices))
    }

    func testAStartInsideANotePassesOverItSilently() throws {
        let file = assembledFile(article)
        var driver = try driver(file)
        let note = try XCTUnwrap(driver.tags.firstIndex(of: .aside("2")))
        let action = driver.observe(timeMs: driver.segmentStartsMs[note] + 10, mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(action, .seek(toMs: driver.segmentStartsMs[note + 2]), "past both notes of the sentence")
        XCTAssertEqual(driver.sequencer.card, .hidden)
    }

    func testAListenerSeekDropsTheCardAndCountsAsAFreshStart() throws {
        let file = assembledFile(article)
        var driver = try driver(file)
        let note = try XCTUnwrap(driver.tags.firstIndex(of: .aside("1")))
        _ = driver.observe(timeMs: driver.segmentStartsMs[note - 1], mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note], mode: .chime, appIsActive: true, now: 0),
                       .cue(label: "1", seekToMs: driver.segmentStartsMs[note + 1]))
        driver.playerMovedOnItsOwn()
        XCTAssertEqual(driver.sequencer.card, .hidden)
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note], mode: .chime, appIsActive: true, now: 0),
                       .seek(toMs: driver.segmentStartsMs[note + 1]), "a seek back into the note does not cue it again")
    }

    // MARK: - Hear note, Stop note, a Timeline tap

    func testHearNoteReadsTheWholeRunThenGoesOnAndTheNoteIsNotOfferedAgain() throws {
        let file = assembledFile(article)
        var driver = try driver(file)
        let first = try XCTUnwrap(driver.tags.firstIndex(of: .aside("2")))
        _ = driver.observe(timeMs: driver.segmentStartsMs[first - 1], mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[first], mode: .chime, appIsActive: true, now: 0),
                       .cue(label: "2", seekToMs: driver.segmentStartsMs[first + 2]))
        _ = driver.observe(timeMs: driver.segmentStartsMs[first + 2], mode: .chime, appIsActive: true, now: 1)

        XCTAssertEqual(driver.hearOfferedNote(), driver.segmentStartsMs[first])
        XCTAssertEqual(driver.sequencer.card, .reading(label: "2"))
        let result = walk(&driver, file: file, from: driver.segmentStartsMs[first])
        XCTAssertEqual(Array(result.played.prefix(3)), [first, first + 1, first + 2], "both notes, then the next sentence")
        XCTAssertEqual(result.cues, [])
        XCTAssertTrue(driver.heard.hasHeardNote("2", itemId: item))
        XCTAssertTrue(driver.heard.hasHeardNote("3", itemId: item))
        XCTAssertEqual(driver.sequencer.card, .hidden, "the card goes once the note was read")

        // Played again from the citing sentence, the heard run passes silently.
        driver.playerMovedOnItsOwn()
        _ = driver.observe(timeMs: driver.segmentStartsMs[first - 1], mode: .chime, appIsActive: true, now: 2)
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[first], mode: .chime, appIsActive: true, now: 2),
                       .seek(toMs: driver.segmentStartsMs[first + 2]))
    }

    func testStopNoteGoesOnAfterTheRun() throws {
        let file = assembledFile(article)
        var driver = try driver(file)
        let first = try XCTUnwrap(driver.tags.firstIndex(of: .aside("2")))
        XCTAssertEqual(driver.hearNote(label: "2"), driver.segmentStartsMs[first])
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[first], mode: .chime, appIsActive: true, now: 0), .none)
        XCTAssertEqual(driver.stopHearing(), driver.segmentStartsMs[first + 2])
        XCTAssertEqual(driver.sequencer.card, .hidden)
        XCTAssertFalse(driver.heard.hasHeardNote("2", itemId: item), "a note cut short is not heard")
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[first + 2], mode: .chime, appIsActive: true, now: 0), .none)
    }

    func testATimelineTapOnANoteNotPlayingReadsIt() throws {
        // A file can start anywhere: the tap moves straight to the note, and nothing playing before does not matter.
        let file = assembledFile(article)
        var driver = try driver(file)
        let note = try XCTUnwrap(driver.tags.firstIndex(of: .aside("1")))
        let start = try XCTUnwrap(driver.hearNote(label: "1"))
        XCTAssertEqual(start, driver.segmentStartsMs[note])
        let result = walk(&driver, file: file, from: start)
        XCTAssertEqual(result.played.first, note, "the note is read, not offered")
        XCTAssertEqual(result.cues, ["2"], "the next citation still chimes")
        XCTAssertNil(driver.hearNote(label: "9"), "a label the file does not read")
    }

    func testANoteEndingTheTextMovesToTheEndOfTheFile() throws {
        let text = "A first claim stands here. Only one claim here.[^1]\n\n[^1]: The note.\n"
        let file = assembledFile(text)
        var driver = try driver(file)
        let note = try XCTUnwrap(driver.tags.firstIndex(of: .aside("1")))
        XCTAssertGreaterThan(note, 0)
        XCTAssertEqual(note, driver.tags.count - 1, "the note is the file's last segment")
        _ = driver.observe(timeMs: driver.segmentStartsMs[note - 1], mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note], mode: .chime, appIsActive: true, now: 0),
                       .cue(label: "1", seekToMs: driver.durationMs))
    }

    func testANoteReadToTheEndOfTheFileIsHeardAndItsCardGoes() throws {
        let text = "A first claim stands here. Only one claim here.[^1]\n\n[^1]: The note.\n"
        let file = assembledFile(text)
        var driver = try driver(file)
        let note = try XCTUnwrap(driver.tags.firstIndex(of: .aside("1")))
        XCTAssertEqual(driver.hearNote(label: "1"), driver.segmentStartsMs[note])
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note], mode: .chime, appIsActive: true, now: 0), .none)
        XCTAssertEqual(driver.sequencer.card, .reading(label: "1"))
        driver.playedToEnd()
        XCTAssertTrue(driver.heard.hasHeardNote("1", itemId: item))
        XCTAssertEqual(driver.sequencer.card, .hidden)
    }

    func testASeekIntoTheMiddleOfANoteNeverCountsItHeard() throws {
        // Read where cited, so the note plays on from the middle; joining it late is not hearing it.
        let file = assembledFile(article)
        var driver = try driver(file)
        let note = try XCTUnwrap(driver.tags.firstIndex(of: .aside("1")))
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note] + 500, mode: .whereCited, appIsActive: true, now: 0), .none)
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note + 1], mode: .whereCited, appIsActive: true, now: 0), .none)
        XCTAssertFalse(driver.heard.hasHeardNote("1", itemId: item))
    }

    func testHearNoteTappedBeforeTheClockLeftTheNoteStillReadsIt() throws {
        // The cue's move has not landed yet when the listener taps Hear note: the clock still reports the note.
        let file = assembledFile(article)
        var driver = try driver(file)
        let note = try XCTUnwrap(driver.tags.firstIndex(of: .aside("1")))
        _ = driver.observe(timeMs: driver.segmentStartsMs[note - 1], mode: .chime, appIsActive: true, now: 0)
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note], mode: .chime, appIsActive: true, now: 0),
                       .cue(label: "1", seekToMs: driver.segmentStartsMs[note + 1]))
        XCTAssertEqual(driver.hearOfferedNote(), driver.segmentStartsMs[note])
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note], mode: .chime, appIsActive: true, now: 0), .none)
        XCTAssertEqual(driver.observe(timeMs: driver.segmentStartsMs[note + 1], mode: .chime, appIsActive: true, now: 0), .none)
        XCTAssertTrue(driver.heard.hasHeardNote("1", itemId: item), "read from its start to its end")
    }

    func testALongNoteSplitIntoSeveralChunksIsFoundWhole() throws {
        let long = (1...60).map { "Clause \($0) of a very long note that keeps going." }.joined(separator: " ")
        let text = "The claim.[^1] The next sentence.\n\n[^1]: \(long)\n"
        let file = assembledFile(text)
        var driver = try driver(file)
        let asides = driver.tags.indices.filter { driver.tags[$0] == .aside("1") }
        XCTAssertGreaterThan(asides.count, 1, "the note is several chunks")
        XCTAssertEqual(asides, Array(asides.first!...asides.last!), "in a row")
        XCTAssertEqual(driver.runStartsMs, [driver.segmentStartsMs[asides[0]]])
        let result = walk(&driver, file: file)
        XCTAssertEqual(result.cues, ["1"])
        XCTAssertEqual(asideLabels(result.played, driver), [])
    }
}
