@testable import SessionKit
import XCTest

/// Which "Figure N" captions give a clip for a picture with no printed text, and which leave the page as it is (#4587).
/// Rectangles are page fractions with the origin at the bottom left, so "above" is a larger y.
final class PDFFigureCaptionLocatorTests: XCTestCase {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PDFNormalizedRect {
        PDFNormalizedRect(x: x, y: y, width: w, height: h)
    }

    /// A paragraph of `count` body lines, `top` down to the bottom of the last, in a column from `x` of width `w`.
    private func paragraph(top: Double, lines count: Int, x: Double = 0.10, width w: Double = 0.80) -> [PDFNormalizedRect] {
        (0..<count).map { rect(x, top - 0.02 - Double($0) * 0.022, w, 0.018) }
    }

    private func caption(_ id: String = "c1", top: Double, x: Double = 0.10, width w: Double = 0.80, height: Double = 0.036) -> PDFFigureCaptionLocator.Caption {
        .init(id: id, bounds: rect(x, top - height, w, height))
    }

    private func assertRect(_ actual: PDFNormalizedRect?, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                            _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("no region. \(message)", file: file, line: line) }
        XCTAssertEqual(actual.x, x, accuracy: 1e-9, "x \(message)", file: file, line: line)
        XCTAssertEqual(actual.y, y, accuracy: 1e-9, "y \(message)", file: file, line: line)
        XCTAssertEqual(actual.width, w, accuracy: 1e-9, "width \(message)", file: file, line: line)
        XCTAssertEqual(actual.height, h, accuracy: 1e-9, "height \(message)", file: file, line: line)
    }

    private let inset = PDFFigureCaptionLocator.edgeInset

    // MARK: The usual layout and its mirror

    func testCaptionBelowItsFigureClipsTheEmptyBandAboveTheCaption() {
        // Body text ends at 0.80 (its last line spans 0.758 to 0.776), the figure fills the gap, the caption sits
        // under it, and body text carries on a paragraph's gap below the caption.
        let above = paragraph(top: 0.95, lines: 8)             // lowest line bottom 0.95 - 0.02 - 7 * 0.022 = 0.776
        let figureCaption = caption(top: 0.46)                 // 0.424 ... 0.46
        let below = paragraph(top: 0.41, lines: 6)             // highest line top 0.41 - 0.02 + 0.018 = 0.408
        let regions = PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: above + below)

        XCTAssertEqual(regions.map(\.captionId), ["c1"])
        assertRect(regions.first?.bounds, 0.10, 0.46 + inset, 0.80, (0.776 - inset) - (0.46 + inset), "caption below")
    }

    func testCaptionAboveItsFigureClipsTheEmptyBandBelowTheCaption() {
        // Publishers that caption on top: the paragraph above ends a normal gap over the caption, so only the band
        // under the caption is empty.
        let above = paragraph(top: 0.95, lines: 4)             // lowest bottom 0.95 - 0.02 - 3 * 0.022 = 0.864
        let figureCaption = caption(top: 0.84)                 // 0.804 ... 0.84; gap above 0.024 is under the minimum
        let below = paragraph(top: 0.45, lines: 8)             // first line top 0.45 - 0.02 + 0.018 = 0.448
        let regions = PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: above + below)

        assertRect(regions.first?.bounds, 0.10, 0.448 + inset, 0.80, (0.804 - inset) - (0.448 + inset), "caption above")
    }

    func testTheBandIsKeptOffTheTextThatBoundsItAndExcludesTheCaption() throws {
        let regions = PDFFigureCaptionLocator.regions(
            captions: [caption(top: 0.46)], textBlocks: paragraph(top: 0.95, lines: 8) + paragraph(top: 0.41, lines: 6))
        let band = try XCTUnwrap(regions.first?.bounds)
        XCTAssertGreaterThan(band.y, 0.46, "starts above the caption's top edge")
        XCTAssertLessThan(band.y + band.height, 0.776, "ends below the text above")
    }

    // MARK: Columns

    func testAFigureInOneColumnOfATwoColumnPageSpansThatColumnOnly() {
        // Left column: text, figure, caption, text. The right column has text running the whole height, which must
        // neither bound the band nor widen it.
        let left = paragraph(top: 0.95, lines: 8, x: 0.08, width: 0.40) + paragraph(top: 0.41, lines: 6, x: 0.08, width: 0.40)
        let right = paragraph(top: 0.95, lines: 30, x: 0.52, width: 0.40)
        let figureCaption = caption(top: 0.46, x: 0.08, width: 0.40)
        let regions = PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: left + right)

        assertRect(regions.first?.bounds, 0.08, 0.46 + inset, 0.40, (0.776 - inset) - (0.46 + inset), "left column")
    }

    func testAFullWidthFigureInATwoColumnPaperSpansBothColumns() {
        // Both columns have text above and below; the caption runs across the page, so the band does too and is
        // bounded by the lower of the two columns' text above it.
        let above = paragraph(top: 0.95, lines: 8, x: 0.08, width: 0.40)       // lowest bottom 0.776
            + paragraph(top: 0.95, lines: 9, x: 0.52, width: 0.40)             // lowest bottom 0.754
        let below = paragraph(top: 0.41, lines: 6, x: 0.08, width: 0.40) + paragraph(top: 0.41, lines: 6, x: 0.52, width: 0.40)
        let figureCaption = caption(top: 0.46, x: 0.08, width: 0.84)
        let regions = PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: above + below)

        assertRect(regions.first?.bounds, 0.08, 0.46 + inset, 0.84, (0.754 - inset) - (0.46 + inset), "full width")
    }

    func testTheOtherColumnsCaptionIsNotAnObstacleToThisColumnsFigure() {
        // Two column figures side by side, each with its caption: neither caption bounds the other's band.
        let leftText = paragraph(top: 0.95, lines: 8, x: 0.08, width: 0.40) + paragraph(top: 0.41, lines: 6, x: 0.08, width: 0.40)
        let rightText = paragraph(top: 0.95, lines: 8, x: 0.52, width: 0.40) + paragraph(top: 0.41, lines: 6, x: 0.52, width: 0.40)
        let regions = PDFFigureCaptionLocator.regions(
            captions: [caption("left", top: 0.46, x: 0.08, width: 0.40), caption("right", top: 0.46, x: 0.52, width: 0.40)],
            textBlocks: leftText + rightText)

        XCTAssertEqual(regions.map(\.captionId), ["left", "right"])
        XCTAssertEqual(regions.map(\.bounds.x), [0.08, 0.52])
    }

    // MARK: Several figures on a page

    func testTwoFiguresWithTextBetweenThemBothGetTheirBand() {
        // Text, figure 1, caption 1, a paragraph, figure 2, caption 2, text.
        let top = paragraph(top: 0.98, lines: 3)                                // lowest bottom 0.98 - 0.02 - 2 * 0.022 = 0.916
        let first = caption("f1", top: 0.66)                                    // 0.624 ... 0.66; band 0.66 ... 0.916
        let between = paragraph(top: 0.62, lines: 3)                            // top of first line 0.60 + 0.018 = 0.618; lowest bottom 0.556
        let second = caption("f2", top: 0.30)                                   // 0.264 ... 0.30; band 0.30 ... 0.556
        let last = paragraph(top: 0.25, lines: 3)                               // top of first line 0.248
        let regions = PDFFigureCaptionLocator.regions(captions: [first, second], textBlocks: top + between + last)

        XCTAssertEqual(regions.map(\.captionId), ["f1", "f2"])
        assertRect(regions.first?.bounds, 0.10, 0.66 + inset, 0.80, (0.916 - inset) - (0.66 + inset), "first")
        assertRect(regions.last?.bounds, 0.10, 0.30 + inset, 0.80, (0.556 - inset) - (0.30 + inset), "second")
    }

    func testTwoCaptionsSharingOneGapGiveNoClipToEither() {
        // Text, figure 1, caption 1, figure 2, caption 2, text: with nothing but the captions between the pictures
        // there is no telling which caption owns the gap between them.
        let top = paragraph(top: 0.98, lines: 3)
        let first = caption("f1", top: 0.66)
        let second = caption("f2", top: 0.30)
        let last = paragraph(top: 0.28, lines: 3)
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [first, second], textBlocks: top + last), [])
    }

    // MARK: Layouts with no clear box

    func testACaptionWithNoGapAroundItGivesNoClip() {
        // Text runs straight into the caption from both sides.
        let above = paragraph(top: 0.95, lines: 20)                             // lowest bottom 0.95 - 0.02 - 19 * 0.022 = 0.512
        let figureCaption = caption(top: 0.49)                                  // 0.454 ... 0.49
        let below = paragraph(top: 0.46, lines: 6)                              // first line top 0.458
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: above + below), [])
    }

    func testAGapUnderTheMinimumHeightGivesNoClip() {
        // 0.04 of the page (about 31 pt) between the text above and the caption.
        let above = paragraph(top: 0.95, lines: 8)                              // lowest bottom 0.776
        let figureCaption = caption(top: 0.776 - 0.04)
        let below = paragraph(top: 0.70 - 0.036, lines: 6)
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: above + below), [])
    }

    func testAnOpenPageAboveTheCaptionGivesNoClipBecauseNothingSaysWhereTheFigureStarts() {
        // The caption is the first thing on the page, as when its figure ends the previous page, or the figure's top
        // is under a running head the extractor left out.
        let figureCaption = caption(top: 0.95)
        let below = paragraph(top: 0.90 - 0.036, lines: 6)
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: below), [])
    }

    func testACaptionAtTheBottomOfThePageClipsTheBandAboveIt() {
        // Nothing below the caption: the only candidate is the band above, bounded by text.
        let above = paragraph(top: 0.95, lines: 8)
        let regions = PDFFigureCaptionLocator.regions(captions: [caption(top: 0.20)], textBlocks: above)
        assertRect(regions.first?.bounds, 0.10, 0.20 + inset, 0.80, (0.776 - inset) - (0.20 + inset), "bottom caption")
    }

    func testTextOnBothSidesAtSimilarDistanceGivesNoClip() {
        // A caption midway between two paragraphs with a figure-sized gap on each side.
        let above = paragraph(top: 0.95, lines: 4)                              // lowest bottom 0.864
        let figureCaption = caption(top: 0.72)                                  // 0.684 ... 0.72; gap above 0.144
        let below = paragraph(top: 0.55, lines: 6)                              // first line top 0.548; gap below 0.136
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: above + below), [])
    }

    func testABandOverEightyFivePercentOfThePageGivesNoClip() {
        // A caption far down a nearly empty page: the band would be the page.
        let above = [rect(0.02, 0.985, 0.96, 0.012)]
        let figureCaption = caption(top: 0.05, x: 0.02, width: 0.96)
        let band = 0.985 - 0.05 - 2 * PDFFigureCaptionLocator.edgeInset
        XCTAssertGreaterThan(0.96 * band, PDFClipLocator.maximumArea)
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: above), [])
    }

    func testANarrowCaptionGivesNoClip() {
        let above = [rect(0.10, 0.95, 0.05, 0.02)]
        let narrow = caption(top: 0.50, x: 0.10, width: 0.05)
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [narrow], textBlocks: above), [])
    }

    func testFigureTextNextToTheCaptionMeansTheFigureAlreadyHasItsClip() {
        // PDFClipLocator already made a region from this figure's printed text, right above the caption.
        let above = paragraph(top: 0.95, lines: 8)
        let ownText = rect(0.20, 0.50, 0.60, 0.20)
        let regions = PDFFigureCaptionLocator.regions(
            captions: [caption(top: 0.46)], textBlocks: above + [ownText], figureRegions: [ownText])
        XCTAssertEqual(regions, [])
    }

    func testFigureTextOfAnotherFigureFarFromTheCaptionDoesNotBlockIt() {
        let above = paragraph(top: 0.95, lines: 8)
        let faraway = rect(0.20, 0.82, 0.30, 0.04)
        let regions = PDFFigureCaptionLocator.regions(captions: [caption(top: 0.46)], textBlocks: above, figureRegions: [faraway])
        XCTAssertEqual(regions.count, 1)
    }

    func testUnusableRectanglesAreIgnored() {
        let above = paragraph(top: 0.95, lines: 8)
        let bad = [rect(0.1, 0.5, .nan, 0.02), rect(0.1, 0.5, 0.5, 0), rect(2, 2, 0.5, 0.1)]
        let regions = PDFFigureCaptionLocator.regions(
            captions: [caption(top: 0.46), .init(id: "broken", bounds: rect(0.1, 0.1, .infinity, 0.1))], textBlocks: above + bad)
        XCTAssertEqual(regions.map(\.captionId), ["c1"])
    }

    func testALineStraddlingTheCaptionsEdgeIsNeverInsideTheBox() {
        // A line whose box overlaps the caption's top by 2 pt-ish is neither above nor below it; the band must not
        // swallow it on its way to the next line.
        let figureCaption = PDFFigureCaptionLocator.Caption(id: "c1", bounds: rect(0.10, 0.50, 0.80, 0.036)) // top 0.536
        let straddler = rect(0.10, 0.53, 0.80, 0.018)                                                       // 0.53 ... 0.548
        let far = rect(0.10, 0.85, 0.80, 0.018)
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: [straddler, far]), [])
    }

    func testABlockOnlyPartlyOverInTheColumnIsNeverInsideTheBox() {
        // A wide equation that overlaps a narrow column's band by under a third of the column: it is not the column's
        // neighbour, but a clip of that column must not contain part of it.
        let figureCaption = PDFFigureCaptionLocator.Caption(id: "c1", bounds: rect(0.10, 0.40, 0.35, 0.036))
        let equation = rect(0.35, 0.60, 0.40, 0.018)
        let above = rect(0.10, 0.90, 0.35, 0.018)
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [figureCaption], textBlocks: [equation, above]), [])
    }

    func testAnEdgeTouchingTextDoesNotBlockTheBand() {
        // Text that only shares an edge with the band (the box is kept off it by `edgeInset`) is fine.
        let regions = PDFFigureCaptionLocator.regions(
            captions: [caption(top: 0.46)], textBlocks: paragraph(top: 0.95, lines: 8) + paragraph(top: 0.41, lines: 6))
        XCTAssertEqual(regions.count, 1)
    }

    func testNoCaptionsMeansNoRegions() {
        // A "Figure 3 shows…" sentence in body text is a text block, never a caption.
        XCTAssertEqual(PDFFigureCaptionLocator.regions(captions: [], textBlocks: paragraph(top: 0.95, lines: 30)), [])
    }

    // MARK: Which lines are captions

    func testWhichLinesOpenAFigureCaption() {
        let table: [(String, Bool)] = [
            ("Figure 3. Cells stained for actin.", true),
            ("Figure 3: Cells stained for actin.", true),
            ("Fig. 2. Cells", true),
            ("Fig 2 Cells stained", true),
            ("FIGURE 4", true),
            ("FIG. 4. Overview", true),
            ("Figure S2 (left) Tumour size", true),
            ("Figure 12.3 Enlarged", true),
            ("Figure 3 shows that cells were stained.", false),
            ("Figure 3 shows", false),
            ("As shown in Figure 3.", false),
            ("  Figure 3. Indented is not a caption start after trimming is the caller's job", false),
            ("figure 3. lower case body prose", false),
            ("Figures 3 and 4 show", false),
            ("Figurehead of the 3rd", false),
            ("", false),
        ]
        for (text, expected) in table {
            XCTAssertEqual(PDFFigureCaption.isCaptionStart(text), expected, "\"\(text)\"")
        }
    }

    func testTheLabelOfACaption() {
        XCTAssertEqual(PDFFigureCaption.label(of: "Figure 3. Cells stained for actin."), "Figure 3")
        XCTAssertEqual(PDFFigureCaption.label(of: "Fig. 2: Cells"), "Figure 2")
        XCTAssertEqual(PDFFigureCaption.label(of: "FIGURE 4"), "Figure 4")
        XCTAssertEqual(PDFFigureCaption.label(of: "Figure S2 (left) Tumour"), "Figure S2")
        XCTAssertEqual(PDFFigureCaption.label(of: "Figure 12.3 Enlarged"), "Figure 12.3")
        XCTAssertNil(PDFFigureCaption.label(of: "Figure 3 shows that"))
        XCTAssertNil(PDFFigureCaption.label(of: "Plain body text"))
    }
}
