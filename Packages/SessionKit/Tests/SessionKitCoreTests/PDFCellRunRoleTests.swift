@testable import SessionKit
import XCTest

/// What a run of cell-like PDF lines is: a table, figure text or neither (#4588).
final class PDFCellRunRoleTests: XCTestCase {
    private func role(_ start: Int, _ end: Int, tables: [Int] = [], figures: [Int] = [], gaps: [Int: Double]? = nil,
                      nearTable: Bool = false, nearFigure: Bool = false) -> PDFCellRunRole.Role? {
        // By default every figure caption sits just under the run (12 pt, about one line of 10 pt text).
        let gaps = gaps ?? Dictionary(uniqueKeysWithValues: figures.map { ($0, 12.0) })
        return PDFCellRunRole.role(start: start, end: end, tableCaptions: tables, figureCaptions: figures,
                                   figureCaptionGaps: gaps, bodySize: 10,
                                   nearTableCaption: nearTable, nearFigureCaption: nearFigure)
    }

    /// arXiv 2608.09666v1 page 4, in reading order: the pipeline diagram's labels are lines 1 to 42, "Fig. 1."
    /// is line 43, "TABLE 2" line 48. The diagram's lowest labels end 21 to 42 pt above the caption (pdftotext
    /// bounding boxes, depending on where PDFKit ends the run). The Test Desk saw the diagram's card labelled
    /// "Table, page 4", scrolled away before "Fig. 1." was read (2026-11-24).
    func testDiagramLabelsAboveTheirFigureCaptionAreFigureTextOnAPageWithATable() {
        XCTAssertEqual(role(1, 42, tables: [48], figures: [43], gaps: [43: 21], nearTable: true, nearFigure: true), .figure)
        XCTAssertEqual(role(1, 40, tables: [48], figures: [43], gaps: [43: 42], nearTable: true, nearFigure: true), .figure)
    }

    func testCaptionSwallowedByTheRunStillCounts() {
        // A short "Fig. 2" line can look like a cell, so the run reaches past it.
        XCTAssertEqual(role(1, 9, figures: [8], nearTable: true, nearFigure: true), .figure)
    }

    func testTableAboveAPictureOnlyFigureStaysATable() {
        // The picture stands between the table's last row and the figure's caption.
        XCTAssertEqual(role(10, 20, figures: [21], gaps: [21: 140], nearTable: true, nearFigure: true), .table)
        XCTAssertEqual(role(10, 20, figures: [21], gaps: [21: 61], nearTable: true, nearFigure: true), .table)
        XCTAssertEqual(role(10, 20, figures: [21], gaps: [21: 60], nearTable: true, nearFigure: true), .figure)
    }

    func testCaptionWithNoKnownPlaceOrBesideTheRunDoesNotTakeIt() {
        XCTAssertEqual(role(10, 20, figures: [21], gaps: [:], nearTable: true, nearFigure: true), .table)
        // Higher on the page than the run's lowest line: another column's caption.
        XCTAssertEqual(role(10, 20, figures: [21], gaps: [21: -200], nearTable: true, nearFigure: true), .table)
    }

    func testTableCaptionWithinReachStillMakesATable() {
        // "Table 2" just above, a figure caption just below: the table's own caption wins.
        XCTAssertEqual(role(10, 14, tables: [8], figures: [15], nearTable: true, nearFigure: true), .table)
        XCTAssertEqual(role(10, 12, tables: [13], nearTable: true), .table)
        XCTAssertEqual(role(10, 20, tables: [22], figures: [23], nearTable: true, nearFigure: true), .table)
    }

    func testFigureCaptionAboveARunDoesNotTakeIt() {
        // A long table running on under a figure's caption stays a table.
        XCTAssertEqual(role(10, 20, figures: [8], nearTable: true, nearFigure: true), .table)
        XCTAssertEqual(role(10, 20, figures: [10], nearTable: true, nearFigure: true), .table)
    }

    func testFigureCaptionBeyondReachDoesNotTakeAPageTable() {
        XCTAssertEqual(role(10, 20, figures: [24], nearTable: true, nearFigure: true), .table)
        XCTAssertEqual(role(10, 20, figures: [23], nearTable: true, nearFigure: true), .figure)
    }

    func testShortRunsAndUncaptionedPages() {
        XCTAssertNil(role(10, 11, tables: [12], figures: [13], nearTable: true, nearFigure: true))
        XCTAssertEqual(role(10, 12, figures: [13]), .figure)
        XCTAssertNil(role(10, 13, nearTable: true))
        XCTAssertEqual(role(10, 14, nearTable: true), .table)
        XCTAssertEqual(role(10, 12, nearFigure: true), .figure)
        XCTAssertNil(role(10, 20))
        XCTAssertNil(role(5, 4, figures: [6], nearFigure: true))
    }
}
