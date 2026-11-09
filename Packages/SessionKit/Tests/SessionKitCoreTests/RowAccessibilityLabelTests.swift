import XCTest
@testable import SessionKit

/// #3730: a row's button says which row it belongs to.
final class RowAccessibilityLabelTests: XCTestCase {
    func testTheActionIsFollowedByTheRowName() {
        XCTAssertEqual(RowAccessibilityLabel.label("Details", row: "Why the tide turns"), "Details, Why the tide turns")
        XCTAssertEqual(RowAccessibilityLabel.label("Resume this session", row: "Earlier session · Nov 3, 2026"),
                       "Resume this session, Earlier session · Nov 3, 2026")
    }

    func testTwoRowsGetTwoLabels() {
        XCTAssertNotEqual(RowAccessibilityLabel.label("Open Margin", row: "12%", "First"),
                          RowAccessibilityLabel.label("Open Margin", row: "40%", "Second"))
    }

    func testPartsAreJoinedWithACommaAndEmptyPartsDropped() {
        XCTAssertEqual(RowAccessibilityLabel.label("Remove Margin", row: "2:15 in", nil, "  ", "A thought"), "Remove Margin, 2:15 in, A thought")
    }

    func testNoRowWordsLeavesTheActionAlone() {
        XCTAssertEqual(RowAccessibilityLabel.label("Details", row: nil), "Details")
        XCTAssertEqual(RowAccessibilityLabel.label("Details", row: ""), "Details")
        XCTAssertEqual(RowAccessibilityLabel.label("Details", row: " \n\t "), "Details")
        XCTAssertEqual(RowAccessibilityLabel.label("Details"), "Details")
    }

    func testWhitespaceAndLineBreaksInTheRowNameBecomeOneSpace() {
        XCTAssertEqual(RowAccessibilityLabel.label("Details", row: "  line one\n\nline   two\t"), "Details, line one line two")
    }

    func testAnUnnormalizedUnicodeNameIsKeptAsIs() {
        let decomposed = "Cafe\u{301} notes"
        XCTAssertEqual(RowAccessibilityLabel.label("Details", row: decomposed), "Details, \(decomposed)")
    }

    func testALongNameIsCutAtAWordAndMarked() {
        let long = String(repeating: "word ", count: 40)
        let label = RowAccessibilityLabel.label("Open Margin", row: long)
        XCTAssertTrue(label.hasSuffix("word…"), label)
        XCTAssertLessThanOrEqual(label.count, "Open Margin, ".count + RowAccessibilityLabel.rowNameLimit + 1)
    }

    func testOneVeryLongWordIsCutWhereItIs() {
        let label = RowAccessibilityLabel.label("Details", row: String(repeating: "x", count: 300))
        XCTAssertEqual(label, "Details, " + String(repeating: "x", count: RowAccessibilityLabel.rowNameLimit) + "…")
    }

    func testANameExactlyAtTheLimitIsNotCut() {
        let exact = String(repeating: "y", count: RowAccessibilityLabel.rowNameLimit)
        XCTAssertEqual(RowAccessibilityLabel.label("Details", row: exact), "Details, \(exact)")
    }
}
