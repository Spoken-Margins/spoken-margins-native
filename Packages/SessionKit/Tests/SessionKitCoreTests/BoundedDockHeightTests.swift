import XCTest
@testable import SessionKit

/// #1933: at the largest text sizes the pinned playback dock filled half the screen and squeezed the Now view.
final class BoundedDockHeightTests: XCTestCase {
    func testADockThatFitsKeepsItsOwnHeight() {
        XCTAssertEqual(BoundedDockHeight.height(content: 200, container: 844), 200, accuracy: 0.001)
    }

    func testATallDockStopsAtTheCap() {
        // About 380 pt of dock at AX5 on a 6.1-inch phone: held to 40% of the screen, so the Now view keeps the rest.
        XCTAssertEqual(BoundedDockHeight.height(content: 380, container: 844), 337.6, accuracy: 0.001)
    }

    func testAnIPhoneSELeavesTheNowViewAtLeastAThirdOfTheScreen() {
        let screen = 667.0
        let dock = BoundedDockHeight.height(content: 380, container: screen)
        XCTAssertGreaterThanOrEqual(screen - dock, screen / 3)
    }

    func testBeforeTheFirstMeasureTheDockTakesTheCapSoItDoesNotCollapse() {
        XCTAssertEqual(BoundedDockHeight.height(content: 0, container: 844), 337.6, accuracy: 0.001)
    }

    func testAnUnknownContainerDoesNotConstrainTheDock() {
        XCTAssertEqual(BoundedDockHeight.height(content: 380, container: 0), 380, accuracy: 0.001)
        XCTAssertEqual(BoundedDockHeight.height(content: 0, container: 0), 0, accuracy: 0.001)
    }
}
