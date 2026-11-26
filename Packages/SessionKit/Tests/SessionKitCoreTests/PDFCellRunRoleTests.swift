@testable import SessionKit
import XCTest

/// What a run of cell-like PDF lines is: a table, figure text or neither (#4588).
final class PDFCellRunRoleTests: XCTestCase {
    private func role(_ start: Int, _ end: Int, tables: [Int] = [], ownFigure: Bool = false,
                      nearTable: Bool = false, nearFigure: Bool = false) -> PDFCellRunRole.Role? {
        PDFCellRunRole.role(start: start, end: end, tableCaptions: tables, hasOwnFigureCaption: ownFigure,
                            nearTableCaption: nearTable, nearFigureCaption: nearFigure)
    }

    private func own(_ start: Int, _ end: Int, tables: [Int] = [], figures: [Int], count: Int = 100,
                     labels: Set<Int> = []) -> PDFCellRunRole.FigureCaption? {
        PDFCellRunRole.ownFigureCaption(start: start, end: end, tableCaptions: tables, figureCaptions: figures,
                                        lineCount: count, isLabel: { labels.contains($0) })
    }

    // MARK: arXiv 2608.09666v1 page 4, as PDFKit reads it on iOS (hosted Mac dump, 2026-11-24)

    /// The pipeline diagram's labels are lines 1 to 41 (cells, "SFT" last). Then come "Base Model EA-3B" (42, too
    /// wide for a cell), "Planning · Tool Calling · Evidence Synthesis" (43, taken for an equation) and
    /// "(b) Supervised Finetuning" (44), then "Fig. 1." (45) and "TABLE 2" (50). The lowest label ends 21 pt
    /// above the caption. The Test Desk saw the card labelled "Table, page 4", off screen when "Fig. 1." was
    /// read, and heard "Base Model EA-3B" read aloud.
    func testDiagramOnArxivPage4IsAFigureWithItsTrailingLabels() {
        let caption = own(1, 41, tables: [50], figures: [45], labels: [42, 43, 44])
        XCTAssertEqual(caption, PDFCellRunRole.FigureCaption(line: 45, labels: [42, 43, 44]))
        XCTAssertTrue(PDFCellRunRole.isJustBelow(gap: 21, bodySize: 10))
        XCTAssertEqual(role(1, 41, tables: [50], ownFigure: true, nearTable: true, nearFigure: true), .figure)
        // Before #4588: the page's table caption made it a table.
        XCTAssertEqual(role(1, 41, tables: [50], ownFigure: false, nearTable: true, nearFigure: true), .table)
    }

    // MARK: Finding the run's own caption

    func testCaptionRightAfterTheRun() {
        XCTAssertEqual(own(1, 9, figures: [10]), PDFCellRunRole.FigureCaption(line: 10, labels: []))
    }

    func testCaptionSwallowedByTheRunStillCounts() {
        // A short "Fig. 2" line can look like a cell, so the run reaches past it.
        XCTAssertEqual(own(1, 9, figures: [8]), PDFCellRunRole.FigureCaption(line: 8, labels: []))
        XCTAssertNil(own(1, 9, figures: [1]), "a caption that opens the run is above its lines")
    }

    func testAnythingButALabelOnTheWayMeansTheCaptionIsNotTheRuns() {
        // A sentence between them.
        XCTAssertNil(own(1, 9, figures: [12], labels: [10]))
        // A table caption between them.
        XCTAssertNil(own(1, 9, tables: [11], figures: [12], labels: [10, 11]))
    }

    func testAtMostFourLabelsBeforeTheCaption() {
        XCTAssertEqual(own(1, 9, figures: [14], labels: [10, 11, 12, 13])?.labels, [10, 11, 12, 13])
        XCTAssertNil(own(1, 9, figures: [15], labels: [10, 11, 12, 13, 14]))
    }

    func testNoCaptionBeforeThePageEnds() {
        XCTAssertNil(own(1, 9, figures: [], count: 12, labels: [10, 11]))
        XCTAssertNil(own(5, 4, figures: [6]))
    }

    // MARK: How close under the figure the caption sits

    func testTableAboveAPictureOnlyFigureStaysATable() {
        // The picture stands between the table's last row and the figure's caption.
        XCTAssertFalse(PDFCellRunRole.isJustBelow(gap: 140, bodySize: 10))
        XCTAssertFalse(PDFCellRunRole.isJustBelow(gap: 61, bodySize: 10))
        XCTAssertTrue(PDFCellRunRole.isJustBelow(gap: 60, bodySize: 10))
        // Higher on the page than the figure's lowest line: another column's caption.
        XCTAssertFalse(PDFCellRunRole.isJustBelow(gap: -200, bodySize: 10))
        XCTAssertTrue(PDFCellRunRole.isJustBelow(gap: -5, bodySize: 10))
    }

    // MARK: The role

    func testTableCaptionWithinReachStillMakesATable() {
        // "Table 2" just above, its own figure caption just below: the table's own caption wins.
        XCTAssertEqual(role(10, 14, tables: [8], ownFigure: true, nearTable: true, nearFigure: true), .table)
        XCTAssertEqual(role(10, 12, tables: [13], nearTable: true), .table)
    }

    func testShortRunsAndUncaptionedPages() {
        XCTAssertNil(role(10, 11, tables: [12], ownFigure: true, nearTable: true, nearFigure: true))
        XCTAssertNil(role(10, 11, ownFigure: true))
        XCTAssertEqual(role(10, 12, ownFigure: true), .figure)
        XCTAssertNil(role(10, 13, nearTable: true))
        XCTAssertEqual(role(10, 14, nearTable: true), .table)
        XCTAssertEqual(role(10, 12, nearFigure: true), .figure)
        XCTAssertNil(role(10, 20))
        XCTAssertNil(role(5, 4, ownFigure: true, nearFigure: true))
    }
}
