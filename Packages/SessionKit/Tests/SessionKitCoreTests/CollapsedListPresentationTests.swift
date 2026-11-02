import XCTest
@testable import SessionKit

final class CollapsedListPresentationTests: XCTestCase {
    func testAnEmptyListShowsNothingAndHasNoToggle() {
        let list = CollapsedListPresentation(total: 0, isExpanded: false)
        XCTAssertEqual(list.shownCount, 0)
        XCTAssertEqual(list.hiddenCount, 0)
        XCTAssertFalse(list.showsToggle)
    }

    func testOneAndTwoItemsShowInFullWithNoToggle() {
        for total in [1, 2] {
            let list = CollapsedListPresentation(total: total, isExpanded: false)
            XCTAssertEqual(list.shownCount, total)
            XCTAssertEqual(list.hiddenCount, 0)
            XCTAssertFalse(list.showsToggle, "\(total) items have nothing to hide")
        }
    }

    func testThreeItemsShowTwoAndOfferTheOtherOne() {
        let list = CollapsedListPresentation(total: 3, isExpanded: false)
        XCTAssertEqual(list.shownCount, 2)
        XCTAssertEqual(list.hiddenCount, 1)
        XCTAssertTrue(list.showsToggle)
        XCTAssertEqual(list.toggleTitle, "Show all 3")
        XCTAssertEqual(list.toggleHint, "Shows 1 more")
    }

    func testThirtyItemsStayTwoRowsUntilOpened() {
        let collapsed = CollapsedListPresentation(total: 30, isExpanded: false)
        XCTAssertEqual(collapsed.shownCount, 2)
        XCTAssertEqual(collapsed.hiddenCount, 28)
        XCTAssertEqual(collapsed.toggleTitle, "Show all 30")
        let open = CollapsedListPresentation(total: 30, isExpanded: true)
        XCTAssertEqual(open.shownCount, 30)
        XCTAssertEqual(open.hiddenCount, 0)
        XCTAssertTrue(open.showsToggle)
        XCTAssertEqual(open.toggleTitle, "Show fewer")
    }

    func testAnExpandedListThatShrinksToTwoDropsItsToggle() {
        // Delete Permanently on the third of three: the group is still "expanded" in state but has nothing to fold.
        let list = CollapsedListPresentation(total: 2, isExpanded: true)
        XCTAssertEqual(list.shownCount, 2)
        XCTAssertFalse(list.showsToggle)
    }

    func testANegativeTotalIsTreatedAsEmpty() {
        XCTAssertEqual(CollapsedListPresentation(total: -4, isExpanded: true).shownCount, 0)
    }
}
