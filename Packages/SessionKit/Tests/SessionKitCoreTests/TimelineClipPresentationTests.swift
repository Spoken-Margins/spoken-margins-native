import XCTest
@testable import SessionKit

/// The words and the size of a Timeline row's table or figure picture (#3895).
final class TimelineClipPresentationTests: XCTestCase {
    func testTheActionNamesTheKind() {
        XCTAssertEqual(TimelineClipPresentation.viewActionTitle(kind: .table), "View table")
        XCTAssertEqual(TimelineClipPresentation.viewActionTitle(kind: .figure), "View figure")
        XCTAssertEqual(TimelineClipPresentation.viewActionTitle(kind: nil), "View table")
    }

    func testTheSpokenLabelNamesTheLabelTheKindAndThePage() {
        XCTAssertEqual(TimelineClipPresentation.spokenLabel(kind: .table, label: "Table 2", pageIndex: 6),
                       "Table 2, clip of the table, page 7")
        XCTAssertEqual(TimelineClipPresentation.spokenLabel(kind: .figure, label: "Fig. 3", pageIndex: 0),
                       "Fig. 3, clip of the figure, page 1")
    }

    func testTheSpokenLabelFallsBackToTheKindsWordAndLeavesOutAnUnknownPage() {
        for label in [nil, "", "  \n "] as [String?] {
            XCTAssertEqual(TimelineClipPresentation.spokenLabel(kind: .figure, label: label, pageIndex: nil),
                           "Figure, clip of the figure", "label \(String(describing: label))")
        }
        XCTAssertEqual(TimelineClipPresentation.spokenLabel(kind: .table, label: "Table 1", pageIndex: -1),
                       "Table 1, clip of the table")
        XCTAssertEqual(TimelineClipPresentation.spokenLabel(kind: .table, label: "  Table 1 ", pageIndex: 2),
                       "Table 1, clip of the table, page 3", "the label is trimmed")
    }

    func testARowPictureIsCappedAtTheDesignedHeight() {
        XCTAssertEqual(TimelineClipPresentation.rowMaximumHeight, 220)
    }
}
