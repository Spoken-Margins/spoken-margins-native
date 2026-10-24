import XCTest
@testable import SessionKit

final class EdgeSwipeBackTrackerTests: XCTestCase {
    private let width = 400.0

    private func drag(_ tracker: inout EdgeSwipeBackTracker, _ horizontal: Double, vertical: Double = 0, follows: Bool = true) {
        tracker.changed(horizontal: horizontal, vertical: vertical, containerWidth: width, followsFinger: follows)
    }

    func testScreenFollowsTheFingerOnceTheDragIsSideways() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 20, vertical: 18)
        XCTAssertEqual(tracker.offset, 0, "A drag that is not yet clearly sideways moves nothing")
        XCTAssertFalse(tracker.showsUnderlay)

        drag(&tracker, 60)
        XCTAssertEqual(tracker.offset, 60)
        XCTAssertTrue(tracker.showsUnderlay)

        drag(&tracker, 150, vertical: 10)
        XCTAssertEqual(tracker.offset, 150)
    }

    func testOffsetStaysWithinTheScreenAndNeverGoesNegative() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 60)
        drag(&tracker, 900)
        XCTAssertEqual(tracker.offset, width)
        drag(&tracker, -80)
        XCTAssertEqual(tracker.offset, 0, "Dragging back past the edge never peeks the other way")
    }

    func testClaimIsLatchedSoAWanderingDragDoesNotSnapBack() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 60)
        drag(&tracker, 100, vertical: 90)
        XCTAssertTrue(tracker.isClaimed)
        XCTAssertEqual(tracker.offset, 100)
    }

    func testAMostlyVerticalDragNeverMovesTheScreenAndCancels() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 40, vertical: 200)
        drag(&tracker, 120, vertical: 300)
        XCTAssertEqual(tracker.offset, 0)
        XCTAssertEqual(tracker.ended(horizontal: 120, vertical: 300, velocity: 900, containerWidth: width), .cancel)
    }

    func testReduceMotionKeepsTheScreenStillButStillJudgesTheRelease() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 60, follows: false)
        drag(&tracker, 200, follows: false)
        XCTAssertEqual(tracker.offset, 0)
        XCTAssertFalse(tracker.showsUnderlay)
        XCTAssertEqual(tracker.ended(horizontal: 200, vertical: 0, velocity: 0, containerWidth: width), .commit)
    }

    func testReleaseUsesTheWholeScreenWidth() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 100)
        // 100 pt of a 400 pt screen is a quarter: slow, so it springs back. Measured against the 32 pt
        // strip the drag starts in, nearly every drag would commit.
        XCTAssertEqual(tracker.ended(horizontal: 100, vertical: 0, velocity: 100, containerWidth: width), .cancel)
    }

    func testReleaseIsReportedOncePerTouch() {
        var tracker = EdgeSwipeBackTracker()
        XCTAssertNil(tracker.ended(horizontal: 300, vertical: 0, velocity: 0, containerWidth: width), "An end with no drag in progress does nothing")

        drag(&tracker, 200)
        XCTAssertEqual(tracker.ended(horizontal: 200, vertical: 0, velocity: 0, containerWidth: width), .commit)
        XCTAssertNil(tracker.ended(horizontal: 200, vertical: 0, velocity: 0, containerWidth: width), "A second end for the same touch is ignored")
    }

    func testTouchesAreIgnoredWhileTheScreenSettles() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 200)
        let outcome = tracker.ended(horizontal: 200, vertical: 0, velocity: 0, containerWidth: width)!
        tracker.settle(outcome, containerWidth: width)
        XCTAssertEqual(tracker.offset, width)

        drag(&tracker, 10)
        XCTAssertEqual(tracker.offset, width, "A new touch can't pull a committing screen back")
        XCTAssertEqual(tracker.phase, .settling)
    }

    func testCancelSettlesBackToZeroAndResetClearsEverything() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 80)
        let outcome = tracker.ended(horizontal: 80, vertical: 0, velocity: 0, containerWidth: width)!
        XCTAssertEqual(outcome, .cancel)
        tracker.settle(outcome, containerWidth: width)
        XCTAssertEqual(tracker.offset, 0)

        tracker.reset()
        XCTAssertEqual(tracker, EdgeSwipeBackTracker())
        XCTAssertFalse(tracker.showsUnderlay)
    }

    func testSettleBeforeAReleaseDoesNothing() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 120)
        tracker.settle(.commit, containerWidth: width)
        XCTAssertEqual(tracker.offset, 120, "Only a release can send the screen away")
    }

    func testAbandonedDragLeavesNothingDrawn() {
        var tracker = EdgeSwipeBackTracker()
        drag(&tracker, 150)
        tracker.reset()
        XCTAssertEqual(tracker.offset, 0)
        XCTAssertEqual(tracker.phase, .idle)
        XCTAssertNil(tracker.ended(horizontal: 150, vertical: 0, velocity: 0, containerWidth: width), "The end of an abandoned touch is ignored")
    }

    func testNonFiniteInputNeverMovesTheScreen() {
        var tracker = EdgeSwipeBackTracker()
        tracker.changed(horizontal: .nan, vertical: 0, containerWidth: width, followsFinger: true)
        tracker.changed(horizontal: 100, vertical: 0, containerWidth: 0, followsFinger: true)
        XCTAssertEqual(tracker.offset, 0)
    }
}
