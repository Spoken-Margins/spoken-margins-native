import XCTest
@testable import SessionKit

final class ScrubTouchRuleTests: XCTestCase {
    func testATouchNearTheBarFollowsAndOneFarAboveOrBelowCancels() {
        let rows: [(Double, ScrubTouchRule.Outcome)] = [
            (0, .follow), (22, .follow), (-22, .follow), (44, .follow),
            (88, .follow), (-88, .follow),
            (88.5, .cancel), (-88.5, .cancel), (300, .cancel), (-300, .cancel),
            (.infinity, .cancel), (-.infinity, .cancel), (.nan, .cancel),
        ]
        for (offset, expected) in rows {
            XCTAssertEqual(ScrubTouchRule.outcome(verticalOffset: offset), expected, "offset \(offset)")
        }
    }

    func testTheCancelDistanceIsAtLeastATouchTargetSoADragAlongTheBarNeverCancels() {
        XCTAssertGreaterThanOrEqual(ScrubTouchRule.cancelDistance, 44)
    }
}
