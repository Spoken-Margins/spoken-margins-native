import XCTest
@testable import SessionKit

/// #3848: one Margin reads "1 Margin", not "1 Margins", in the Margins tab's count and in an item's heading.
final class MarginCountTextTests: XCTestCase {
    func testTheCountIsSingularForExactlyOne() {
        XCTAssertEqual(MarginCountText.count(0), "0 Margins")
        XCTAssertEqual(MarginCountText.count(1), "1 Margin")
        XCTAssertEqual(MarginCountText.count(2), "2 Margins")
        XCTAssertEqual(MarginCountText.count(11), "11 Margins")
        XCTAssertEqual(MarginCountText.count(-1), "0 Margins")
    }

    func testTheItemLineKeepsNewestAndTheRightNoun() {
        XCTAssertEqual(MarginCountText.itemLine(1, isNewest: true), "Newest · 1 Margin")
        XCTAssertEqual(MarginCountText.itemLine(1, isNewest: false), "1 Margin")
        XCTAssertEqual(MarginCountText.itemLine(2, isNewest: true), "Newest · 2 Margins")
        XCTAssertEqual(MarginCountText.itemLine(0, isNewest: false), "0 Margins")
    }
}
