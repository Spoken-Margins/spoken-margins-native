import XCTest
@testable import SessionKit

/// #3777: the timeline the assembler writes for a prepared file is the one the footnote session reads. Both now use
/// `AssembledNarrationTimeline`, so these pin what the session depends on: an aside's own segment (empty range, its own
/// words), segment ids saved Margins point at, a split chunk's pieces, and a session built from an item's real text.
final class AssembledNarrationTimelineTests: XCTestCase {
    private let tides = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2][^3] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    [^3]: Park, Ports, 2022.
    """

    private func article(_ text: String) -> Item {
        Item(id: "item-1", title: "Tides", mediaType: "article", text: text, externalReference: nil, status: "ready")
    }

    /// The file the assembler makes from `text` prepared with its notes read where cited: the plan without the notes
    /// chapter's copies, in start order, `chunkMs` of audio each and `silenceMs` after.
    private func assembled(_ text: String, chunkMs: Int = 1_000, silenceMs: Int = 500) throws
        -> (timeline: TranscriptTimeline, chunks: [NarrationChunkPlanner.Chunk], owners: [Int]) {
        let speech = try XCTUnwrap(PreparedSpeechText(item: article(text), document: nil))
        let plan = NarrationChunkPlanner.articlePlan(speech.text, asides: true).chunks
        let ordered = plan.enumerated()
            .filter { if case .definition? = $0.element.footnote { return false } else { return true } }
            .sorted { ($0.element.startOffset, $0.offset) < ($1.element.startOffset, $1.offset) }
            .map(\.element)
        var builder = AssembledNarrationTimeline(projection: speech.assemblyProjection(asides: true), sourceText: speech.itemText)
        var owners: [Int] = []
        var cursor = 0
        for (position, chunk) in ordered.enumerated() {
            let added = builder.append(startOffset: chunk.startOffset, sourceLength: chunk.sourceLength, text: chunk.text,
                                       startMs: cursor, endMs: cursor + chunkMs)
            XCTAssertEqual(added.lowerBound, owners.count, "indexes follow on from the last chunk's")
            owners += Array(repeating: position, count: added.count)
            cursor += chunkMs + silenceMs
        }
        return (TranscriptTimeline(segments: builder.segments, chapters: [], durationMs: cursor), ordered, owners)
    }

    func testEachAsideHasOneSegmentWithAnEmptyRangeAndItsOwnWords() throws {
        let file = try assembled(tides)
        let asides = file.chunks.enumerated().filter { if case .aside? = $0.element.footnote { true } else { false } }
        XCTAssertEqual(asides.count, 3, "the fixture cites three notes")
        for (position, chunk) in asides {
            let segments = file.owners.indices.filter { file.owners[$0] == position }.map { file.timeline.segments[$0] }
            XCTAssertEqual(segments.count, 1, "an aside is never split")
            let segment = try XCTUnwrap(segments.first)
            XCTAssertEqual(segment.startChar, segment.endChar, "an aside reads no source characters")
            XCTAssertEqual(segment.text, chunk.text, "the session finds a note by its own words")
        }
    }

    func testSegmentIdsKeepTheFormSavedMarginsPointAt() throws {
        let file = try assembled(tides)
        XCTAssertEqual(file.timeline.segments.map(\.id),
                       file.timeline.segments.indices.map { "supertonic-seg-\(String(format: "%04d", $0 + 1))" })
        XCTAssertEqual(file.timeline.segments.first?.id, "supertonic-seg-0001")
    }

    func testAChunkSplitAcrossSkippedReferencesNamesEachPieceByItsSpokenWords() throws {
        let references = (1...40).map { "[\($0)] A. Author. A cited title number \($0). Journal of Examples. 2019." }
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Levels rose as expected in every cohort we followed.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
        ] + references.map { StructuredDocumentLine(text: $0, role: .reference, pageIndex: 1) } + [
            StructuredDocumentLine(text: "Appendix", role: .heading, pageIndex: 2, level: 2),
            StructuredDocumentLine(text: "Supplementary methods are read aloud.", role: .body, pageIndex: 2),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 3)
        let item = Item(id: "paper", title: "Paper", mediaType: "pdf", text: document.text, externalReference: nil, status: "ready")
        let speech = try XCTUnwrap(PreparedSpeechText(item: item, document: document))
        let projection = speech.assemblyProjection()
        var builder = AssembledNarrationTimeline(projection: projection, sourceText: speech.itemText)
        let added = builder.append(startOffset: 0, sourceLength: projection.text.count, text: "the whole paper",
                                   startMs: 0, endMs: 10_000)
        XCTAssertGreaterThan(added.count, 1, "precondition: the chunk is split where the text jumps")
        let spoken = projection.text
        for segment in builder.segments {
            XCTAssertNotEqual(segment.text, "the whole paper", "a piece is named by what it says, not by the whole chunk")
            XCTAssertFalse(segment.text.isEmpty)
            XCTAssertTrue(spoken.contains(segment.text), "\"\(segment.text)\" is said in the narration")
        }
        XCTAssertTrue(builder.segments.contains { $0.text.contains("Supplementary methods") })
    }

    /// The chain the app runs on a prepared article in "Chime where cited": the item's own prepared text, the plan with
    /// note chunks, the assembled timeline, and the session (`Gate1AppModel.loadFootnoteMediaChimeSession`).
    func testASessionIsBuiltFromAnArticlesAssembledTimelineWithOneRunPerCitation() throws {
        let file = try assembled(tides)
        let speech = try XCTUnwrap(PreparedSpeechText(item: article(tides), document: nil))
        var session = try XCTUnwrap(FootnoteMediaChimeSession(
            itemId: "item-1", mediaKey: "file:///prepared/item-1.m4a", timeline: file.timeline, articleText: speech.text))
        XCTAssertEqual(session.runStartsMs.count, 2, "[^1] is one run; [^2][^3] are cited together and are one run")
        let firstRun = try XCTUnwrap(session.runStartsMs.first)
        let before = try XCTUnwrap(file.timeline.segments.last { $0.startMs < firstRun })
        XCTAssertEqual(session.observe(timeMs: before.startMs, mode: .chime, appIsActive: true, now: 0), .none)
        guard case .cue(let label, let seekToMs) = session.observeBoundary(timeMs: firstRun, mode: .chime, appIsActive: true, now: 0) else {
            return XCTFail("playback that runs on into a note cues it")
        }
        XCTAssertEqual(label, "1")
        XCTAssertGreaterThan(seekToMs, firstRun, "the cue moves past the note")
    }

    func testAFilePreparedWithTheNotesAtTheEndHasNoSession() throws {
        let speech = try XCTUnwrap(PreparedSpeechText(item: article(tides), document: nil))
        var builder = AssembledNarrationTimeline(projection: speech.assemblyProjection(), sourceText: speech.itemText)
        var cursor = 0
        for chunk in NarrationChunkPlanner.articlePlan(speech.text).chunks {
            builder.append(startOffset: chunk.startOffset, sourceLength: chunk.sourceLength, text: chunk.text,
                           startMs: cursor, endMs: cursor + 1_000)
            cursor += 1_500
        }
        XCTAssertNil(FootnoteMediaChimeSession(itemId: "item-1", mediaKey: "file:///prepared/item-1.m4a",
                                               timeline: TranscriptTimeline(segments: builder.segments, chapters: [], durationMs: cursor),
                                               articleText: speech.text))
    }
}
