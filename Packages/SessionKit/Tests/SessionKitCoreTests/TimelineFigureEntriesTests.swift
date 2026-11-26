import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// A picture-only PDF figure's entry for the Timeline: where it stands and what its caption says (#4587, PR 2).
final class TimelineFigureEntriesTests: XCTestCase {
    private typealias Part = (id: String, role: StructuredDocument.Role, text: String)

    private func captionFloat(_ id: String = "float-p1-c1", label: String = "Figure 3", caption: String = "b",
                              page: Int = 0) -> StructuredDocument.Float {
        .init(id: id, kind: .figure, label: label, pageIndex: page, bounds: .init(x: 0.1, y: 0.4, width: 0.5, height: 0.2),
              captionSegmentId: caption, textSegmentId: nil)
    }

    private func document(_ parts: [Part], floats: [StructuredDocument.Float], pageCount: Int = 4) -> StructuredDocument {
        var text = ""
        var segments: [StructuredDocument.Segment] = []
        for part in parts {
            if !text.isEmpty { text += "\n\n" }
            segments.append(.init(id: part.id, role: part.role, range: .init(start: text.count, length: part.text.count)))
            text += part.text
        }
        return StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: pageCount, textSHA256: nil),
            text: text, segments: segments, markers: [], floats: floats)
    }

    private func detail(_ document: StructuredDocument) -> ItemDetailState {
        ItemDetailState(id: "paper", text: document.text).includingTimelineSource(document)
    }

    /// The figure entries of one body segment that holds `body` after an opening sentence.
    private func figures(in body: String, label: String = "Figure 3", after: String = "") -> [TimelineSourceContent.Entry] {
        let text = "Opening sentence of the paper.\n" + body + after
        return detail(document([("b", .body, text)], floats: [captionFloat(label: label)])).timelineSource.figures
    }

    // MARK: Where the entry stands

    func testOneCaptionFloatGivesOneEntryAtTheCaptionLineWithItsLabelPageAndExcerpt() throws {
        let intro = "Opening sentence of the paper.\nMore text before the picture."
        let d = document([("b", .body, intro + "\nFigure 3. Micrographs of treated cells. Scale bars, 10 µm.\nBody after."),
                          ("c", .body, "A later paragraph.")],
                         floats: [captionFloat(page: 2)])
        let content = detail(d).timelineSource
        let entry = try XCTUnwrap(content.figures.first)
        XCTAssertEqual(content.figures.count, 1)
        XCTAssertEqual(entry.id, "source.figure.float-p1-c1")
        XCTAssertEqual(entry.start, intro.count + 1, "the first character of the caption line, in Characters")
        XCTAssertEqual(entry.label, "Figure 3")
        XCTAssertEqual(entry.pageIndex, 2)
        XCTAssertEqual(entry.role, .caption)
        XCTAssertEqual(entry.floatId, "float-p1-c1")
        XCTAssertEqual(entry.floatKind, .figure)
        XCTAssertEqual(entry.text, "Figure 3. Micrographs of treated cells.")
        XCTAssertEqual(content.entries.count, 2, "the figure is not an entry: Now's overlap check reads entries as a partition")
        XCTAssertTrue(content.entries.allSatisfy { $0.floatId == nil && $0.label == nil })
    }

    func testFiguresStandInTextOrderWhateverOrderTheFloatsAreIn() {
        let body = "Intro.\nFigure 1. First.\nBody.\nFigure 2. Second.\nEnd."
        let d = document([("b", .body, body)], floats: [
            captionFloat("float-p2-c1", label: "Figure 2", page: 1), captionFloat("float-p1-c1", label: "Figure 1")])
        let figures = detail(d).timelineSource.figures
        XCTAssertEqual(figures.map(\.label), ["Figure 1", "Figure 2"])
        XCTAssertEqual(figures.map(\.start), figures.map(\.start).sorted())
    }

    func testAPageIndexOutsideTheDocumentIsNoPage() throws {
        let d = document([("b", .body, "Intro.\nFigure 3. Cells.")], floats: [captionFloat(page: 9)], pageCount: 2)
        XCTAssertNil(try XCTUnwrap(detail(d).timelineSource.figures.first).pageIndex)
    }

    func testAFloatWithNoCaptionLineFoundGetsNoEntry() {
        let d = document([("b", .body, "Intro.\nNothing like a caption here.")], floats: [captionFloat()])
        XCTAssertEqual(detail(d).timelineSource.figures, [])
    }

    func testAFloatWhoseSegmentCannotHoldACaptionGetsNoEntry() {
        let d = document([("b", .footnote, "Figure 3. A footnote that names a figure.")], floats: [captionFloat()])
        XCTAssertEqual(detail(d).timelineSource.figures, [])
    }

    func testOnlyTextFloatsGiveNoFigures() {
        var d = document([("a", .body, "Intro.\nFigure 1. Cells.\n"), ("t", .figureText, "(a) 10 (b) 20")],
                         floats: [.init(id: "float-p1-1", kind: .figure, label: "Figure 1", pageIndex: 0,
                                        bounds: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.2),
                                        captionSegmentId: "a", textSegmentId: "t")])
        d.segments[1].floatId = "float-p1-1"
        let content = detail(d).timelineSource
        XCTAssertEqual(content.figures, [])
        XCTAssertEqual(content.entries.last?.floatId, "float-p1-1", "the text figure keeps its own row")
    }

    func testAFloatNamedByASegmentIsTheTextsRowNotAFigure() {
        // A document saved before `textSegmentId` existed names its float from the segment instead.
        let d = document([("a", .body, "Intro.\nFigure 1. Cells."), ("t", .figureText, "(a) 10 (b) 20")],
                         floats: [captionFloat("f", label: "Figure 1", caption: "a")])
        var named = d
        named.segments[1].floatId = "f"
        XCTAssertEqual(detail(named).timelineSource.figures, [])
    }

    func testAnArticleAPodcastAndAPDFWithNoFloatsGiveNoFigures() {
        XCTAssertEqual(ItemDetailState(id: "a", text: "Figure 3. Cells.").includingTimelineSource(nil).timelineSource.figures, [])
        XCTAssertEqual(TimelineSourceContent(text: "Figure 3. Cells.").figures, [])
        let d = document([("b", .body, "Intro.\nFigure 3. Cells.")], floats: [])
        XCTAssertEqual(detail(d).timelineSource.figures, [])
    }

    func testADocumentThatIsNotTheItemsTextGivesNoFigures() {
        let d = document([("b", .body, "Intro.\nFigure 3. Cells.")], floats: [captionFloat()])
        XCTAssertEqual(ItemDetailState(id: "a", text: "A different text.").includingTimelineSource(d).timelineSource.figures, [])
    }

    func testTwoItemsWithTheSameFloatIdsKeepTheirOwnEntries() throws {
        let one = document([("b", .body, "One.\nFigure 3. The first paper.")], floats: [captionFloat()])
        let two = document([("b", .body, "Two, longer intro.\nFigure 3. The second paper.")], floats: [captionFloat()])
        let a = try XCTUnwrap(detail(one).timelineSource.figures.first)
        let b = try XCTUnwrap(detail(two).timelineSource.figures.first)
        XCTAssertEqual(a.floatId, b.floatId)
        XCTAssertNotEqual(a.start, b.start)
        XCTAssertNotEqual(a.text, b.text)
    }

    // MARK: The excerpt

    func testTheExcerptIsTheLabelAndTheCaptionsFirstSentence() {
        let tail = "\nA following line of body text."
        // (what the row is about, the caption's lines, what follows them in the same segment, the excerpt)
        let rows: [(String, String, String, String)] = [
            ("a full stop and a capital", "Figure 3. Micrographs of treated cells. Scale bars, 10 µm.", tail,
             "Figure 3. Micrographs of treated cells."),
            ("the label alone on its line, the caption on the next", "Figure 3.\nMicrographs of treated cells. More.", tail,
             "Figure 3.\nMicrographs of treated cells."),
            ("a label and a blank line", "Figure 3.\n\nMore body.", "", "Figure 3."),
            ("a caption ending in ).", "Figure 3. Cells stained blue (see text).", tail,
             "Figure 3. Cells stained blue (see text)."),
            ("no full stop, then a body line", "Figure 3. Scale bars, 10 µm\nThe cells grew. After that.", tail,
             "Figure 3. Scale bars, 10 µm\nThe cells grew."),
            ("a caption at the end of the segment", "Figure 3. The last caption, with no full stop", "",
             "Figure 3. The last caption, with no full stop"),
            ("the label's own full stop", "Fig. 3: Overview of the method. Panels (a) and (b) show the cells.", tail,
             "Fig. 3: Overview of the method."),
            ("a decimal is not a sentence end", "Figure 3: ratio 0.5 vs 1.5 in the cohort. Next sentence.", tail,
             "Figure 3: ratio 0.5 vs 1.5 in the cohort."),
            ("a question", "Figure 3. Is it a cell? Yes it is.", tail, "Figure 3. Is it a cell?"),
            ("a closing quote after the full stop", "Figure 3. The \"ring.\" Then more.", tail, "Figure 3. The \"ring.\""),
            ("an abbreviation before a lowercase word", "Figure 3. Cells, approx. half of them stained. Then.", tail,
             "Figure 3. Cells, approx. half of them stained."),
            ("a capitalised label with no punctuation", "FIGURE 3 Cells in culture. Details follow.", tail,
             "FIGURE 3 Cells in culture."),
            ("a carriage return and line feed", "Figure 3. Cells.\r\nNext line", "", "Figure 3. Cells."),
            ("accents and emoji", "Figure 3. Cellules é🙂 colorées. Suite.", tail, "Figure 3. Cellules é🙂 colorées."),
            ("a legend with no capital after its full stops", "Figure 3. (a) cells. (b) more cells. (c) the rest", "",
             "Figure 3. (a) cells. (b) more cells. (c) the rest"),
            ("the next line's first sentence when the caption has no stop", "Figure 3. Scale bars, 10 µm", tail,
             "Figure 3. Scale bars, 10 µm\nA following line of body text."),
        ]
        for (name, body, after, expected) in rows {
            XCTAssertEqual(figures(in: body, after: after).first?.text, expected, name)
        }
    }

    func testALongCaptionWithNoSentenceEndIsCutAtThreeHundredCharactersBackToASpace() throws {
        let words = Array(repeating: "particles", count: 60).joined(separator: " ")
        let text = try XCTUnwrap(figures(in: "Figure 3. \(words) end of it", after: "\nBody.").first?.text)
        XCTAssertLessThanOrEqual(text.count, TimelineSourceContent.figureExcerptLimit)
        XCTAssertGreaterThan(text.count, TimelineSourceContent.figureExcerptLimit - 12, "it runs to the cut, not to the first space")
        XCTAssertTrue(text.hasSuffix("particles"), "it ends on a whole word: \(text.suffix(12))")
    }

    func testTheExcerptNeverRunsPastItsCaptionsSegment() {
        let d = document([("b", .body, "Intro.\nFigure 3. A caption with no stop"), ("c", .body, "so a second segment follows it")],
                         floats: [captionFloat()])
        XCTAssertEqual(detail(d).timelineSource.figures.first?.text, "Figure 3. A caption with no stop")
    }

    func testACaptionThatIsAHeadingSegmentIsItsOwnExcerpt() {
        let d = document([("a", .body, "Intro."), ("b", .heading, "Figure 3. Cells in culture and the dish"),
                          ("c", .body, "Body that follows.")], floats: [captionFloat()])
        XCTAssertEqual(detail(d).timelineSource.figures.first?.text, "Figure 3. Cells in culture and the dish")
    }

    // MARK: A long source, and a relaunch

    func testFortyCaptionFloatsInAMillionCharactersBuildTheirEntriesQuickly() throws {
        let filler = (1...600).map { "Line \($0) of ordinary body text that runs on." }.joined(separator: "\n")
        var parts: [Part] = []
        var floats: [StructuredDocument.Float] = []
        for index in 1...40 {
            parts.append(("body\(index)", .body, filler + "\nFigure \(index). Caption number \(index). Words after."))
            floats.append(captionFloat("float-p\(index)-c1", label: "Figure \(index)", caption: "body\(index)", page: index % 4))
        }
        let d = document(parts, floats: floats)
        XCTAssertGreaterThan(d.text.count, 1_000_000)
        let source = try XCTUnwrap(PDFClipSource(document: d, text: d.text))
        let start = Date()
        let figures = TimelineSourceContent.figureEntries(text: d.text, document: d, source: source)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(figures.count, 40)
        XCTAssertEqual(figures.map(\.start), figures.map(\.start).sorted())
        XCTAssertEqual(figures.last?.text, "Figure 40. Caption number 40.")
        // A budget, not a wait: an excerpt that reads to the end of its segment, or a caption search that restarts from
        // the top of the text for each figure, would take many times this. A ceiling, not a target.
        XCTAssertLessThan(elapsed, 0.5, "40 figure entries in a 1.1 MB text")
    }

    func testTheEntriesAreTheSameAfterTheDocumentIsReadBackFromTheStore() throws {
        let d = document([("a", .body, "Intro.\nFigure 1. First cells. More."), ("b", .body, "Middle.\nFigure 2. Second cells.")],
                         floats: [captionFloat("float-p1-c1", label: "Figure 1", caption: "a"),
                                  captionFloat("float-p2-c1", label: "Figure 2", caption: "b", page: 1)])
        let before = detail(d).timelineSource.figures
        XCTAssertEqual(before.count, 2)

        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "paper", title: "Paper", mediaType: "pdf", text: d.text, externalReference: nil, status: "ready"))
        try store.saveStructuredDocument(d, itemId: "paper")
        let loaded = try XCTUnwrap(store.loadStructuredDocument(itemId: "paper"))

        XCTAssertEqual(ItemDetailState(id: "paper", text: d.text).includingTimelineSource(loaded).timelineSource.figures, before)
    }
}
