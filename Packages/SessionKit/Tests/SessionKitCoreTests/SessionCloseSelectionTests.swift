import XCTest
@testable import SessionKit

/// #583: the mini player's X closed the playing session and switched the open item page to the playing item.
final class SessionCloseSelectionTests: XCTestCase {
    func testClosingFromAnotherItemsPageKeepsThatPage() {
        XCTAssertEqual(SessionCloseSelection.itemId(closing: "item-a", pageOnScreen: "item-b", navigatesHome: false), "item-b")
    }

    func testClosingFromThePlayingItemsPageKeepsIt() {
        XCTAssertEqual(SessionCloseSelection.itemId(closing: "item-a", pageOnScreen: "item-a", navigatesHome: false), "item-a")
    }

    func testClosingWithNoItemPageSelectsTheClosedItemAsBefore() {
        XCTAssertEqual(SessionCloseSelection.itemId(closing: "item-a", pageOnScreen: nil, navigatesHome: false), "item-a")
        XCTAssertEqual(SessionCloseSelection.itemId(closing: "item-a", pageOnScreen: "", navigatesHome: false), "item-a")
    }

    func testEndSessionGoingHomeSelectsTheClosedItemAsBefore() {
        XCTAssertEqual(SessionCloseSelection.itemId(closing: "item-a", pageOnScreen: "item-b", navigatesHome: true), "item-a")
    }
}
