import XCTest
@testable import SessionKit

/// Which start controls the item screen pins at the bottom and which move into its scrolling content (#5110).
final class ItemStartControlsLayoutTests: XCTestCase {
    func testBelowTheAccessibilitySizesEveryPartStaysPinned() {
        let layout = ItemStartControlsLayout(accessibilityTextSize: false)
        XCTAssertEqual(layout, .allPinned)
        for part in ItemStartControlsLayout.Part.allCases {
            XCTAssertTrue(layout.isPinned(part), "\(part) left the pinned area at a normal text size")
            XCTAssertFalse(layout.isInline(part), "\(part) is drawn twice at a normal text size")
        }
        XCTAssertFalse(layout.capsMainButtonText, "the main button's text is capped at a normal text size")
    }

    func testAtTheAccessibilitySizesOnlyTheMainButtonStaysPinned() {
        let layout = ItemStartControlsLayout(accessibilityTextSize: true)
        XCTAssertEqual(layout, .mainButtonPinned)
        XCTAssertTrue(layout.isPinned(.mainButton), "the main button must stay within thumb reach (#149)")
        for part in [ItemStartControlsLayout.Part.preparingLine, .arrivalLine, .secondChoice] {
            XCTAssertFalse(layout.isPinned(part), "\(part) still takes room in the pinned area at an accessibility size")
            XCTAssertTrue(layout.isInline(part), "\(part) is drawn nowhere at an accessibility size")
        }
        XCTAssertTrue(layout.capsMainButtonText)
    }

    func testEveryPartIsDrawnInExactlyOnePlace() {
        for layout in [ItemStartControlsLayout.allPinned, .mainButtonPinned] {
            for part in ItemStartControlsLayout.Part.allCases {
                XCTAssertNotEqual(layout.isPinned(part), layout.isInline(part), "\(layout): \(part)")
            }
        }
    }
}
