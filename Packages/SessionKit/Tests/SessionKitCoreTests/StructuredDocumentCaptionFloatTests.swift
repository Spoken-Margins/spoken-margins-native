@testable import SessionKit
import XCTest

/// Picture-only figures found from their "Figure N" captions, end to end through the document builder (#4587).
/// Rectangles are page fractions with the origin at the bottom left, so "above" is a larger y.
final class StructuredDocumentCaptionFloatTests: XCTestCase {
    private typealias Line = StructuredDocumentLine
    private let inset = PDFFigureCaptionLocator.edgeInset

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PDFNormalizedRect {
        PDFNormalizedRect(x: x, y: y, width: w, height: h)
    }

    private func line(_ text: String, _ bounds: PDFNormalizedRect?, page: Int = 0, role: StructuredDocument.Role = .body) -> Line {
        Line(text: text, role: role, pageIndex: page, bounds: bounds)
    }

    /// A paragraph of body lines, `top` down, in a column from `x`.
    private func paragraph(_ prefix: String, top: Double, lines count: Int, x: Double = 0.10, width: Double = 0.80, page: Int = 0) -> [Line] {
        (0..<count).map { line("\(prefix) line \($0) of the paragraph.", rect(x, top - 0.02 - Double($0) * 0.022, width, 0.018), page: page) }
    }

    /// A caption of two lines, `top` down: 0.04 tall.
    private func caption(_ number: String, top: Double, x: Double = 0.10, width: Double = 0.80, page: Int = 0,
                         role: StructuredDocument.Role = .body, continuation: StructuredDocument.Role = .body) -> [Line] {
        [line("Figure \(number). Micrographs of treated cells", rect(x, top - 0.018, width, 0.018), page: page, role: role),
         line("stained for actin.", rect(x, top - 0.040, width, 0.018), page: page, role: continuation)]
    }

    /// A page of body text with no caption: it only counts toward the text area.
    private func filler(page: Int) -> [Line] {
        (0..<6).map { line("Filler \(page) line \($0) of the page.", rect(0.10, 0.06 + 0.17 * Double($0), 0.80, 0.02), page: page) }
    }

    /// Text above, a figure with no text, its caption, then text below: the usual layout.
    private func standardPage(page: Int, number: String) -> [Line] {
        paragraph("Above \(page)", top: 0.95, lines: 8, page: page)             // lowest bottom 0.776
            + caption(number, top: 0.46, page: page)                            // 0.42 ... 0.46
            + paragraph("Below \(page)", top: 0.392, lines: 6, page: page)      // first line top 0.39: a paragraph gap under the caption
    }

    private func build(_ lines: [Line], pages: Int = 1, captionTextArea: Bool = true) -> StructuredDocument {
        StructuredDocumentBuilder.build(lines: lines, engine: "test", version: 1, pageCount: pages, captionTextArea: captionTextArea)
    }

    private func withoutBounds(_ lines: [Line]) -> [Line] {
        lines.map { var copy = $0; copy.bounds = nil; return copy }
    }

    private func assertBounds(_ actual: PDFNormalizedRect?, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                              _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("no float. \(message)", file: file, line: line) }
        XCTAssertEqual(actual.x, x, accuracy: 1e-9, "x \(message)", file: file, line: line)
        XCTAssertEqual(actual.y, y, accuracy: 1e-9, "y \(message)", file: file, line: line)
        XCTAssertEqual(actual.width, w, accuracy: 1e-9, "width \(message)", file: file, line: line)
        XCTAssertEqual(actual.height, h, accuracy: 1e-9, "height \(message)", file: file, line: line)
    }

    private func captionSegment(of document: StructuredDocument, containing words: String) -> String? {
        document.segments.first { segment in
            let range = segment.range
            return Array(document.text)[range.start..<range.end].map(String.init).joined().contains(words)
        }?.id
    }

    // MARK: Done when 1: the table of layouts

    func testCaptionBelowItsFigureClipsTheBandAboveIt() throws {
        let document = build(standardPage(page: 0, number: "3"))
        XCTAssertEqual(document.floats.count, 1)
        let float = try XCTUnwrap(document.floats.first)
        XCTAssertEqual(float.id, "float-p1-c1")
        XCTAssertEqual(float.kind, .figure)
        XCTAssertEqual(float.label, "Figure 3")
        XCTAssertEqual(float.pageIndex, 0)
        XCTAssertNil(float.textSegmentId)
        XCTAssertEqual(float.captionSegmentId, captionSegment(of: document, containing: "Figure 3."))
        assertBounds(float.bounds, 0.10, 0.46 + inset, 0.80, (0.776 - inset) - (0.46 + inset), "caption below")
        XCTAssertTrue(document.segments.allSatisfy { $0.floatId == nil }, "no segment links to a caption float")
    }

    func testCaptionAboveItsFigureClipsTheBandBelowIt() {
        // Text, a caption a paragraph gap under it, the figure, then text.
        let lines = paragraph("Above", top: 0.95, lines: 4)                     // lowest bottom 0.864
            + caption("2", top: 0.83)                                           // 0.79 ... 0.83: the gap above is under the minimum
            + paragraph("Below", top: 0.45, lines: 8)                           // first line top 0.448
        let float = build(lines).floats.first
        assertBounds(float?.bounds, 0.10, 0.448 + inset, 0.80, (0.79 - inset) - (0.448 + inset), "caption above")
        XCTAssertEqual(float?.label, "Figure 2")
    }

    func testAFigureInOneColumnOfATwoColumnPageClipsThatColumnOnly() {
        // Reading order is the left column, then the right.
        let left = paragraph("Left above", top: 0.95, lines: 8, x: 0.08, width: 0.40)
            + caption("1", top: 0.46, x: 0.08, width: 0.40)
            + paragraph("Left below", top: 0.392, lines: 6, x: 0.08, width: 0.40)
        let right = paragraph("Right", top: 0.95, lines: 30, x: 0.52, width: 0.40)
        let float = build(left + right).floats.first
        assertBounds(float?.bounds, 0.08, 0.46 + inset, 0.40, (0.776 - inset) - (0.46 + inset), "left column")
    }

    func testAFullWidthFigureInATwoColumnPaperSpansBothColumns() {
        let lines = paragraph("Left above", top: 0.95, lines: 8, x: 0.08, width: 0.40)       // lowest bottom 0.776
            + paragraph("Right above", top: 0.95, lines: 9, x: 0.52, width: 0.40)              // lowest bottom 0.754
            + caption("4", top: 0.46, x: 0.08, width: 0.84)
            + paragraph("Left below", top: 0.392, lines: 6, x: 0.08, width: 0.40)
            + paragraph("Right below", top: 0.392, lines: 6, x: 0.52, width: 0.40)
        let float = build(lines).floats.first
        assertBounds(float?.bounds, 0.08, 0.46 + inset, 0.84, (0.754 - inset) - (0.46 + inset), "full width")
    }

    func testTwoFiguresStackedOnOnePageWithTextBetweenThemBothGetAClip() {
        let lines = paragraph("Top", top: 0.98, lines: 3)                         // lowest bottom 0.916
            + caption("1", top: 0.66)                                              // 0.62 ... 0.66
            + paragraph("Between", top: 0.59, lines: 3)                            // first line top 0.588, lowest bottom 0.526
            + caption("2", top: 0.30)                                              // 0.26 ... 0.30
            + paragraph("Last", top: 0.23, lines: 3)                               // first line top 0.228
        let floats = build(lines).floats
        XCTAssertEqual(floats.map(\.label), ["Figure 1", "Figure 2"], "top-down")
        XCTAssertEqual(floats.map(\.id), ["float-p1-c1", "float-p1-c2"])
        assertBounds(floats.first?.bounds, 0.10, 0.66 + inset, 0.80, (0.916 - inset) - (0.66 + inset), "first")
        assertBounds(floats.last?.bounds, 0.10, 0.30 + inset, 0.80, (0.526 - inset) - (0.30 + inset), "second")
    }

    func testACaptionWithNoGapAroundItGivesNoFloat() {
        let lines = paragraph("Above", top: 0.95, lines: 20)                      // lowest bottom 0.512
            + caption("5", top: 0.49)                                              // 0.45 ... 0.49
            + paragraph("Below", top: 0.41, lines: 6)                              // first line top 0.408
        XCTAssertEqual(build(lines).floats, [])
    }

    func testAFigureAtTheTopOfThePageIsMeasuredToTheTextArea() throws {
        // The figure fills the page from its caption up to the top of the text; the page has nothing above it.
        let top = caption("6", top: 0.60) + paragraph("Below", top: 0.52, lines: 6)  // first line top 0.518, a paragraph gap under it
        let document = build(top + filler(page: 1) + filler(page: 2) + filler(page: 3), pages: 4)
        let float = try XCTUnwrap(document.floats.first)
        XCTAssertEqual(float.id, "float-p1-c1")
        assertBounds(float.bounds, 0.10, 0.60 + inset, 0.80, 0.93 - (0.60 + inset), "top of the page")
    }

    func testACaptionAboveAFigureAtTheBottomOfThePageIsMeasuredToTheTextAreasBottom() throws {
        // Text, a caption a paragraph gap under it, and then the figure down to the bottom of the text: nothing is below.
        let lines = paragraph("Above", top: 0.40, lines: 3) + caption("7", top: 0.30)    // lowest bottom 0.336; caption 0.26 ... 0.30
        let document = build(lines + filler(page: 1) + filler(page: 2) + filler(page: 3), pages: 4)
        let float = try XCTUnwrap(document.floats.first)
        assertBounds(float.bounds, 0.10, 0.06, 0.80, (0.26 - inset) - 0.06, "caption above, figure at the bottom")
        let withoutArea = build(lines + filler(page: 1) + filler(page: 2) + filler(page: 3), pages: 4, captionTextArea: false)
        XCTAssertEqual(withoutArea.floats, [], "nothing says where the figure ends without the text area")
    }

    func testAFigureAtTheBottomOfThePageClipsTheBandAboveItsCaption() throws {
        // The caption sits at the bottom of the text area, so nothing is below it to be a second candidate.
        let lines = paragraph("Above", top: 0.95, lines: 4) + caption("7", top: 0.10)
        let document = build(lines + filler(page: 1) + filler(page: 2) + filler(page: 3), pages: 4)
        let float = try XCTUnwrap(document.floats.first)
        assertBounds(float.bounds, 0.10, 0.10 + inset, 0.80, (0.864 - inset) - (0.10 + inset), "bottom of the page")
    }

    func testAFigureMentionedInBodyTextIsNotACaption() {
        let lines = paragraph("Above", top: 0.95, lines: 8)
            + [line("Figure 3 shows that the cells were stained for actin.", rect(0.10, 0.50, 0.80, 0.018))]
            + paragraph("Below", top: 0.40, lines: 6)
        XCTAssertEqual(build(lines).floats, [])
    }

    func testTheTopFigureIsNotFoundWhenTheTextAreaIsTurnedOff() {
        let top = caption("6", top: 0.60) + paragraph("Below", top: 0.52, lines: 6)  // first line top 0.518, a paragraph gap under it
        let document = build(top + filler(page: 1) + filler(page: 2) + filler(page: 3), pages: 4, captionTextArea: false)
        XCTAssertEqual(document.floats, [])
    }

    // MARK: Which lines make a caption

    func testACaptionReadAsAHeadingWithBodyContinuationLinesIsOneBlock() throws {
        let lines = paragraph("Above", top: 0.95, lines: 8)
            + caption("3", top: 0.46, role: .heading, continuation: .body)
            + paragraph("Below", top: 0.392, lines: 6)
        let document = build(lines)
        let float = try XCTUnwrap(document.floats.first)
        XCTAssertEqual(document.floats.count, 1)
        XCTAssertEqual(float.captionSegmentId, captionSegment(of: document, containing: "Figure 3."), "the heading segment")
        assertBounds(float.bounds, 0.10, 0.46 + inset, 0.80, (0.776 - inset) - (0.46 + inset), "heading caption")
    }

    func testBodyTextSetTightUnderTheCaptionStillLeavesTheBandAboveIt() {
        // The paragraph right under the caption joins its block (a line's gap or less); that only moves the block's
        // bottom, never the band above.
        let lines = paragraph("Above", top: 0.95, lines: 8)
            + caption("3", top: 0.46)
            + paragraph("Tight", top: 0.425, lines: 5)                              // first line top 0.423, 0.003 under the caption
        let float = build(lines).floats.first
        assertBounds(float?.bounds, 0.10, 0.46 + inset, 0.80, (0.776 - inset) - (0.46 + inset), "tight paragraph")
    }

    func testATwentyLineLegendAboveItsFigureIsOneBlockWithAClipBelowIt() {
        let legend = [line("Figure 8. Legend line 0 opens the legend", rect(0.10, 0.88 - 0.018, 0.80, 0.018))]
            + (1..<20).map { line("legend line \($0) carries on", rect(0.10, 0.88 - 0.018 - Double($0) * 0.022, 0.80, 0.018)) }
        let lines = paragraph("Top", top: 0.98, lines: 3)                         // lowest bottom 0.916
            + legend                                                               // 0.88 ... 0.88 - 0.018 - 19 * 0.022 = 0.444
            + paragraph("Below", top: 0.10, lines: 3)                              // first line top 0.098
        let floats = build(lines).floats
        XCTAssertEqual(floats.count, 1)
        assertBounds(floats.first?.bounds, 0.10, 0.098 + inset, 0.80, (0.444 - inset) - (0.098 + inset), "legend above")
    }

    func testPanelLabelsInsideTheBandDoNotBoundOrBlockIt() {
        // "(a)" and "(b)" are text the extractor read inside the figure. They are far enough apart to be no table or
        // figure-text clip of their own, and they are neither a neighbour nor an obstacle for the caption's band.
        let lines = paragraph("Above", top: 0.95, lines: 8)
            + [line("(a)", rect(0.15, 0.62, 0.03, 0.015), role: .figureText), line("(b)", rect(0.75, 0.62, 0.03, 0.015), role: .figureText)]
            + caption("9", top: 0.46)
            + paragraph("Below", top: 0.392, lines: 6)
        let floats = build(lines).floats
        XCTAssertEqual(floats.count, 1)
        assertBounds(floats.first?.bounds, 0.10, 0.46 + inset, 0.80, (0.776 - inset) - (0.46 + inset), "with panel labels")
    }

    func testAFigureWithItsOwnPrintedTextGetsOnlyItsTextClip() throws {
        // A figure with axis text: its clip comes from that text, and a caption float must not show it twice.
        let figureText = [line("0 20 40 60", rect(0.20, 0.52, 0.50, 0.02), role: .figureText),
                          line("dose (mg)", rect(0.20, 0.55, 0.50, 0.02), role: .figureText),
                          line("response", rect(0.20, 0.58, 0.50, 0.02), role: .figureText)]
        let lines = paragraph("Above", top: 0.95, lines: 8) + figureText + caption("3", top: 0.50) + paragraph("Below", top: 0.40, lines: 6)
        let floats = build(lines).floats
        XCTAssertEqual(floats.count, 1)
        XCTAssertNotNil(floats.first?.textSegmentId, "the text float, not a caption float")
    }

    func testTwoCaptionsWithTheSameLabelInOneSegmentGiveNoFloat() {
        // `PDFClipAnchors` finds a caption by its label in its segment: with two it could not tell which is which.
        let lines = paragraph("Above", top: 0.95, lines: 8)
            + caption("3", top: 0.60)
            + paragraph("Middle", top: 0.540, lines: 6)
            + caption("3", top: 0.20)
            + paragraph("End", top: 0.140, lines: 3)
        XCTAssertEqual(build(lines).floats, [])
    }

    func testTwoCaptionsWithTheSameLabelOnDifferentPagesOfOneSegmentGiveNoFloat() {
        // One body segment holds every page's body lines, and `PDFClipAnchors` finds a caption by its label in the
        // segment, so both "Figure 3" cards would land on the first caption.
        let lines = standardPage(page: 0, number: "3") + standardPage(page: 5, number: "3")
        XCTAssertEqual(build(lines, pages: 6).floats, [])
    }

    func testACaptionWhoseLabelIsRepeatedOnAPageTheBuilderSkipsGivesNoFloat() {
        // The other "Figure 3" is on a page with an unplaced line, so it never becomes a block; it still counts.
        let skipped = standardPage(page: 1, number: "3") + [line("A line the extractor could not place.", nil, page: 1)]
        let lines = standardPage(page: 0, number: "3") + skipped
        XCTAssertEqual(build(lines, pages: 2).floats, [])
    }

    func testTheSameLabelInDifferentSegmentsIsNotAmbiguous() {
        // A heading-role caption has a segment of its own, so its label is found there and nowhere else.
        let first = paragraph("Above", top: 0.95, lines: 8) + caption("3", top: 0.46, role: .heading) + paragraph("Below", top: 0.392, lines: 6)
        let second = paragraph("Above", top: 0.95, lines: 8, page: 1) + caption("3", top: 0.46, page: 1, role: .heading)
            + paragraph("Below", top: 0.392, lines: 6, page: 1)
        XCTAssertEqual(build(first + second, pages: 2).floats.map(\.id), ["float-p1-c1", "float-p2-c1"])
    }

    func testAPageWithAnUnboundedBodyLineGetsNoCaptionFloatButATitleLineDoesNot() {
        let unplaced = standardPage(page: 0, number: "1") + [line("A line the extractor could not place.", nil, page: 0)]
        let titled = standardPage(page: 1, number: "2") + [line("Title of the paper", nil, page: 1, role: .title)]
        let document = build(unplaced + titled, pages: 2)
        XCTAssertEqual(document.floats.map(\.id), ["float-p2-c1"], "page 1 is skipped, page 2 has its figure")
    }

    // MARK: The cap

    /// A page whose figure has printed text: one text float, the first of the document.
    private func textFigurePage(page: Int) -> [Line] {
        [line("0 20 40 60", rect(0.20, 0.52, 0.50, 0.02), page: page, role: .figureText),
         line("dose (mg)", rect(0.20, 0.55, 0.50, 0.02), page: page, role: .figureText),
         line("response", rect(0.20, 0.58, 0.50, 0.02), page: page, role: .figureText)]
    }

    func testFortyFiveCaptionFiguresGiveFortyFloats() {
        let lines = (0..<45).flatMap { standardPage(page: $0, number: "\($0 + 1)") }
        let floats = build(lines, pages: 45).floats
        XCTAssertEqual(floats.count, PDFClipLocator.maximumFloatsPerDocument)
        XCTAssertEqual(floats.map(\.label), (1...40).map { "Figure \($0)" }, "in page order")
    }

    func testTextFloatsComeFirstUnderTheCapAndAGeneratedSixtyPageDocumentStaysFast() {
        let lines = textFigurePage(page: 0) + (1..<60).flatMap { standardPage(page: $0, number: "\($0)") }
        let start = Date()
        let document = build(lines, pages: 60)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(document.floats.count, PDFClipLocator.maximumFloatsPerDocument)
        XCTAssertNotNil(document.floats.first?.textSegmentId, "the text float is first")
        XCTAssertEqual(document.floats.dropFirst().filter { $0.textSegmentId == nil }.count, 39)
        // A ceiling, not a target: if a run goes over it, profile before raising it.
        XCTAssertLessThan(elapsed, 2.0, "building a 60-page document with a caption figure on every page")
    }

    // MARK: What does not change, and what Now and the re-import read

    func testTextSegmentsAndMarkersAreTheSameWithAndWithoutBounds() {
        let lines = standardPage(page: 0, number: "3") + standardPage(page: 1, number: "4")
            + [line("A sentence with a note.12", rect(0.1, 0.3, 0.8, 0.02), page: 1)]
        let withBounds = build(lines, pages: 2)
        let without = build(withoutBounds(lines), pages: 2)
        XCTAssertEqual(withBounds.floats.count, 2)
        XCTAssertEqual(without.floats, [])
        XCTAssertEqual(withBounds.text, without.text)
        XCTAssertEqual(withBounds.segments, without.segments)
        XCTAssertEqual(withBounds.markers, without.markers)
        XCTAssertEqual(withBounds.extraction, without.extraction)
        XCTAssertEqual(withBounds.outline, without.outline)
    }

    func testTheReimportComparisonIgnoresCaptionFloats() {
        let lines = standardPage(page: 0, number: "3")
        let withBounds = build(lines)
        let without = build(withoutBounds(lines))
        XCTAssertEqual(withBounds.floats.count, 1)
        XCTAssertNotEqual(withBounds, without)
        XCTAssertEqual(withBounds.withoutClipGeometry, without.withoutClipGeometry)
        XCTAssertEqual(withBounds.comparedOnReimport, without.comparedOnReimport)
    }

    func testTheReimportComparisonStillIgnoresTextFloatsAndTheirSegmentLinks() {
        let lines = standardPage(page: 0, number: "3") + textFigurePage(page: 1)
        let withBounds = build(lines, pages: 2)
        let without = build(withoutBounds(lines), pages: 2)
        XCTAssertEqual(withBounds.floats.count, 2, "a caption float and a text float")
        XCTAssertTrue(withBounds.segments.contains { $0.floatId != nil })
        XCTAssertEqual(withBounds.comparedOnReimport, without.comparedOnReimport)
    }

    func testNowFindsEachCaptionFloatAtItsCaptionLinesFirstCharacter() throws {
        let document = build(standardPage(page: 0, number: "3") + standardPage(page: 1, number: "4"), pages: 2)
        XCTAssertEqual(document.floats.count, 2)
        let source = try XCTUnwrap(PDFClipSource(document: document, text: document.text))
        let anchors = PDFClipAnchors.make(text: document.text, source: source)
        XCTAssertEqual(anchors.map(\.floatId), ["float-p1-c1", "float-p2-c1"])
        XCTAssertEqual(anchors.map(\.numberLabel), ["Figure 3", "Figure 4"])
        for (anchor, label) in zip(anchors, ["Figure 3.", "Figure 4."]) {
            let characters = Array(document.text)
            XCTAssertEqual(anchor.hasCaption, true)
            XCTAssertEqual(String(characters[anchor.anchor..<anchor.anchor + label.count]), label)
            XCTAssertTrue(anchor.anchor == 0 || characters[anchor.anchor - 1].isNewline, "the first character of its line")
        }
    }

    func testTheDocumentWithCaptionFloatsRoundTripsAndUsesOnlyTheFloatFieldsEveryBuildDecodes() throws {
        let document = build(standardPage(page: 0, number: "3"))
        XCTAssertEqual(document.floats.count, 1)
        let data = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(StructuredDocument.self, from: data), document)

        let allowed: Set<String> = ["id", "kind", "label", "pageIndex", "bounds", "captionSegmentId", "textSegmentId"]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let floats = try XCTUnwrap(object["floats"] as? [[String: Any]])
        for float in floats { XCTAssertTrue(Set(float.keys).isSubset(of: allowed), "\(Set(float.keys).subtracting(allowed))") }
        XCTAssertNil(floats.first?["textSegmentId"], "absent, as an I13 float without its own text")
    }
}
