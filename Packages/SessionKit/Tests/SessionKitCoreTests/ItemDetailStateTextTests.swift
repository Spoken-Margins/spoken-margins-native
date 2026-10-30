import XCTest
@testable import SessionKit

/// A narrated Margin moment plans its lead-in on the text of the item on screen instead of reading the item from
/// the store on the main actor (#2506). That is only safe when the detail is for the same item.
final class ItemDetailStateTextTests: XCTestCase {
    func testTextIsGivenOnlyForTheDetailsOwnItem() {
        let detail = ItemDetailState(id: "article-a", text: "First. Second.")
        XCTAssertEqual(detail.text(forItem: "article-a"), "First. Second.")
        XCTAssertNil(detail.text(forItem: "article-b"))
        XCTAssertNil(detail.text(forItem: ""), "an empty id is not the item")
    }

    func testAnEmptyDetailHasNoTextForAnyRealItem() {
        XCTAssertNil(ItemDetailState().text(forItem: "article-a"))
    }

    func testAnItemWithNoTextGivesAnEmptyStringNotNil() {
        XCTAssertEqual(ItemDetailState(id: "audio-a", text: "").text(forItem: "audio-a"), "")
    }
}
