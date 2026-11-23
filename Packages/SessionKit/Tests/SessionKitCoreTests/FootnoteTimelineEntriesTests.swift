import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3777 Design PR 7: the Timeline lists a matched note as "Footnote 3" at its citation when the item's narration reads
/// the notes where they are cited, and lists nothing where it keeps them at the end, for a PDF or for audio.
final class FootnoteTimelineEntriesTests: XCTestCase {
    private let article = """
    The tide turns twice a day.[^1] Then it rests for a while.

    The moon pulls on it.[^b] The sun pulls less.[^1]

    Nothing here cites a third note.[^missing]

    ## Notes

    [^1]: Smith, Tides, 2020. A long note that goes on past the cut so the row has to shorten it at a word and not in the middle of one.
    [^b]: Moon note.
    """

    // MARK: - Which rows

    func testEveryMatchedNoteIsARowAtItsFirstCitation() throws {
        let rows = FootnoteTimelineEntries.entries(in: article, readsWhereCited: true)
        XCTAssertEqual(rows.map(\.label), ["1", "b"])
        XCTAssertEqual(rows.map(\.title), ["Footnote 1", "Footnote b"])
        let characters = Array(article)
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(String(characters[first.citationStart..<(first.citationStart + 4)]), "[^1]")
        XCTAssertEqual(first.citationStart, article.distance(from: article.startIndex, to: try XCTUnwrap(article.range(of: "[^1]")).lowerBound),
                       "the first citation, not the later one in the second paragraph")
    }

    func testNoRowsWhereTheNotesStayAtTheEnd() {
        XCTAssertEqual(FootnoteTimelineEntries.entries(in: article, readsWhereCited: false), [])
    }

    func testAPdfOrAudioHasNoRows() {
        XCTAssertEqual(FootnoteTimelineEntries.entries(in: article, readsWhereCited: true, isNarratedFromText: false), [])
        var item = ItemDetailState()
        item.text = article
        XCTAssertFalse(FootnoteTimelineEntries.entries(for: item, readsWhereCited: true).isEmpty)
        item.isNativeAudio = true
        XCTAssertEqual(FootnoteTimelineEntries.entries(for: item, readsWhereCited: true), [])
        item.isNativeAudio = false
        item.documentStructure = PDFDocumentStructure(extractionEngine: .pdfKit, analysisStatus: .partial, pageCount: 2, analyzedPageCount: 0)
        XCTAssertEqual(FootnoteTimelineEntries.entries(for: item, readsWhereCited: true), [])
    }

    /// The audit on #5062: the setting alone is not the plan. An article already prepared with the notes at the end keeps
    /// that plan, says "footnote 1" at the marker and reads the notes in their chapter, so a row's tap could not play the
    /// note. The rows follow the one decision the player and every preparation share.
    func testRowsFollowThePlanDecisionNotTheSettingAlone() {
        let plain = NarrationChunkPlanner.identity(ofArticle: article)
        var prepared = PreparedAudioManifest(
            id: "prepared-a", itemId: "a", sourcePackageId: "source",
            signature: .init(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                             synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "prepared-a"),
            state: .readyOffline, plannedChunkCount: 3, articleIdentity: plain)
        prepared.artifact = PreparedAudioArtifact(relativePath: "a.m4a", byteCount: 1, checksumSHA256: "x", durationMs: 1)
        func rows(_ mode: FootnoteMode, pdf: Bool = false, _ manifests: [PreparedAudioManifest] = []) -> [String] {
            let reads = FootnotePlanDecision.asides(mode: mode, isPDF: pdf, articleText: article, manifests: manifests)
            return FootnoteTimelineEntries.entries(in: article, readsWhereCited: reads).map(\.label)
        }
        XCTAssertEqual(rows(.whereCited), ["1", "b"])
        XCTAssertEqual(rows(.chime), ["1", "b"])
        XCTAssertEqual(rows(.atEnd), [])
        XCTAssertEqual(rows(.whereCited, pdf: true), [], "a PDF keeps its footnotes as they are")
        XCTAssertEqual(rows(.whereCited, [prepared]), [], "audio prepared with the notes at the end keeps them there")
        XCTAssertEqual(rows(.chime, [prepared]), [])
        prepared.state = .failed
        prepared.artifact = nil
        prepared.chunks = []
        XCTAssertEqual(rows(.whereCited, [prepared]), ["1", "b"], "a failed preparation holds nothing")
    }

    func testACitationWithNoDefinitionIsNotARow() {
        XCTAssertFalse(FootnoteTimelineEntries.entries(in: article, readsWhereCited: true).contains { $0.label == "missing" })
    }

    func testTextWithoutNotesHasNoRows() {
        for text in ["", "Plain text with no notes.", "A [link] and a [^ broken marker and [^3] with no note."] {
            XCTAssertEqual(FootnoteTimelineEntries.entries(in: text, readsWhereCited: true), [], text)
        }
    }

    /// A row the narrator cannot read where it is cited would be a tap that goes nowhere: the rows are exactly the
    /// plan's aside chunks.
    func testTheRowsAreExactlyTheNotesThePlanReadsWhereCited() {
        let plan = NarrationChunkPlanner.articlePlan(article, asides: true)
        var planned: [String] = []
        for case .aside(let label)? in plan.chunks.map(\.footnote) where !planned.contains(label) { planned.append(label) }
        XCTAssertFalse(planned.isEmpty)
        XCTAssertEqual(FootnoteTimelineEntries.entries(in: article, readsWhereCited: true).map(\.label), planned)
    }

    // MARK: - What a row says

    func testTheDetailIsTheNotesFirstWordsCutAtAWord() throws {
        let row = try XCTUnwrap(FootnoteTimelineEntries.entries(in: article, readsWhereCited: true).first)
        XCTAssertTrue(row.noteText.hasPrefix("Smith, Tides, 2020."))
        XCTAssertTrue(row.detail.hasPrefix("Smith, Tides, 2020."))
        XCTAssertTrue(row.detail.hasSuffix("…"))
        XCTAssertLessThanOrEqual(row.detail.count, FootnoteTimelineEntries.detailCharacterLimit + 1)
        XCTAssertFalse(row.detail.contains("\n"))
        let short = try XCTUnwrap(FootnoteTimelineEntries.entries(in: article, readsWhereCited: true).last)
        XCTAssertEqual(short.detail, "Moon note.", "a short note is shown whole")
    }

    func testTheRowIdIsStablePerLabel() {
        let ids = FootnoteTimelineEntries.entries(in: article, readsWhereCited: true).map(\.id)
        XCTAssertEqual(ids, ["footnote.1", "footnote.b"])
        XCTAssertEqual(ids, FootnoteTimelineEntries.entries(in: article, readsWhereCited: true).map(\.id),
                       "switching modes does not change which row is which")
    }

    /// A seek at the citation means the text after the note, so a tap's fallback goes to the start of the citing sentence.
    func testTheSentenceStartIsBeforeTheCitationForEveryWayAMarkerSitsInASentence() {
        let table: [(text: String, expectedStart: String)] = [
            ("First one. Second one.[^1] Third one.\n\n[^1]: N.", "Second one.[^1] Third one."),
            ("First one. Second one has a mark[^1] in the middle. Third one.\n\n[^1]: N.", "Second one has a mark[^1] in the middle. Third one."),
            ("Only sentence.[^1]\n\n[^1]: N.", "Only sentence.[^1]\n\n[^1]: N."),
            ("First one. Is it so?[^1] Third one.\n\n[^1]: N.", "Is it so?[^1] Third one."),
            ("First one. He said \"stop.\"[^1] Third one.\n\n[^1]: N.", "He said \"stop.\"[^1] Third one."),
            ("First one.[^2] Second one.[^1][^2] Third one.\n\n[^1]: N.\n[^2]: M.", "Second one.[^1][^2] Third one."),
            ("A paragraph ends here.\n\nNext paragraph starts. It cites.[^1] Then more.\n\n[^1]: N.", "It cites.[^1] Then more."),
            ("A paragraph ends without a stop\nNext line cites[^1] it.\n\n[^1]: N.", "Next line cites[^1] it."),
        ]
        for row in table {
            let characters = Array(row.text)
            guard let anchor = FootnoteAnchors.find(in: row.text).first(where: { $0.label == "1" }) else {
                XCTFail("no anchor in: \(row.text)"); continue
            }
            let citation = anchor.citationRange.lowerBound
            let start = FootnoteTimelineEntries.sentenceStart(citedAt: citation, in: characters)
            XCTAssertLessThan(start, citation, row.text)
            XCTAssertEqual(String(characters[start...]).prefix(row.expectedStart.count), row.expectedStart.prefix(row.expectedStart.count), row.text)
        }
    }

    func testTheSentenceStartNeverLeavesTheTextOrReachesTheCitation() {
        XCTAssertEqual(FootnoteTimelineEntries.sentenceStart(citedAt: 0, in: Array("[^1] A note first.\n\n[^1]: N.")), 0)
        XCTAssertEqual(FootnoteTimelineEntries.sentenceStart(citedAt: 99, in: Array("short")), 0)
        for row in FootnoteTimelineEntries.entries(in: article, readsWhereCited: true) {
            XCTAssertLessThan(row.sentenceStart, row.citationStart)
            XCTAssertGreaterThanOrEqual(row.sentenceStart, 0)
        }
    }

    func testANoteWithNothingToSayOnceCleanedHasNoRowBecauseThePlanHasNoAside() {
        let text = "A claim.[^1] Another claim.[^2]\n\n[^1]: \u{21A9}\n[^2]: A real note."
        let plan = NarrationChunkPlanner.articlePlan(text, asides: true)
        var planned: [String] = []
        for case .aside(let label)? in plan.chunks.map(\.footnote) where !planned.contains(label) { planned.append(label) }
        XCTAssertEqual(FootnoteTimelineEntries.entries(in: text, readsWhereCited: true).map(\.label), planned)
    }

    func testEntryByLabelFindsTheRowOrNothing() {
        var item = ItemDetailState()
        item.text = article
        XCTAssertEqual(FootnoteTimelineEntries.entry(label: "b", for: item, readsWhereCited: true)?.noteText, "Moon note.")
        XCTAssertNil(FootnoteTimelineEntries.entry(label: "zzz", for: item, readsWhereCited: true))
        XCTAssertNil(FootnoteTimelineEntries.entry(label: "b", for: item, readsWhereCited: false), "the setting changed under a pending tap")
        item.text = "The text changed."
        XCTAssertNil(FootnoteTimelineEntries.entry(label: "b", for: item, readsWhereCited: true))
    }
}
