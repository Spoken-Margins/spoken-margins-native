import Foundation
import XCTest
@testable import SessionKit

/// #106: when an edge swipe back commits and when it springs back.
final class EdgeSwipeBackRuleTests: XCTestCase {
    private let width = 390.0

    private func outcome(_ horizontal: Double, vertical: Double = 0, velocity: Double = 0, width: Double? = nil) -> EdgeSwipeBackRule.Outcome {
        EdgeSwipeBackRule.outcome(horizontal: horizontal, vertical: vertical, velocity: velocity, containerWidth: width ?? self.width)
    }

    func testSlowShortDragCancels() {
        XCTAssertEqual(outcome(60, velocity: 40), .cancel)
        XCTAssertEqual(outcome(129, velocity: 100), .cancel)
    }

    func testSlowLongDragCommits() {
        XCTAssertEqual(outcome(130, velocity: 20), .commit) // exactly a third
        XCTAssertEqual(outcome(220, velocity: 0), .commit)
        XCTAssertEqual(outcome(390, velocity: 0), .commit)
    }

    func testFastShortFlickCommits() {
        XCTAssertEqual(outcome(40, velocity: 900), .commit)
        XCTAssertEqual(outcome(24, velocity: 600), .commit)
    }

    func testFlickJustUnderTheThresholdsCancels() {
        XCTAssertEqual(outcome(40, velocity: 599), .cancel)
        XCTAssertEqual(outcome(23, velocity: 2000), .cancel) // a slipped touch, not a swipe
        XCTAssertEqual(outcome(0, velocity: 2000), .cancel)
    }

    func testMostlyVerticalDragCancelsAtAnySpeedAndDistance() {
        XCTAssertEqual(outcome(200, vertical: 200, velocity: 2000), .cancel)
        XCTAssertEqual(outcome(200, vertical: -200, velocity: 0), .cancel)
        XCTAssertEqual(outcome(300, vertical: 250, velocity: 0), .cancel)
        XCTAssertEqual(outcome(40, vertical: 300, velocity: 2000), .cancel)
    }

    func testHorizontalDominanceBoundary() {
        // 1.4 times the vertical travel is not enough; it has to exceed it, as the old release check did.
        XCTAssertEqual(outcome(140, vertical: 100, velocity: 0), .cancel)
        XCTAssertEqual(outcome(141, vertical: 100, velocity: 0), .commit)
        XCTAssertEqual(outcome(141, vertical: -100, velocity: 0), .commit)
    }

    func testDraggingTheWrongWayCancels() {
        XCTAssertEqual(outcome(-200, velocity: -1000), .cancel)
        XCTAssertEqual(outcome(-200, velocity: 1000), .cancel)
    }

    func testReversingFastFromPastTheThresholdCancels() {
        XCTAssertEqual(outcome(250, velocity: -600), .cancel)
        XCTAssertEqual(outcome(250, velocity: -100), .commit) // a slight drift back is still a commit
    }

    func testNarrowAndWideContainersScaleTheThreshold() {
        XCTAssertEqual(outcome(100, velocity: 0, width: 300), .commit)
        XCTAssertEqual(outcome(100, velocity: 0, width: 1024), .cancel) // iPad: a third is 341 pt
        XCTAssertEqual(outcome(342, velocity: 0, width: 1024), .commit)
    }

    func testNonsenseInputsCancel() {
        XCTAssertEqual(outcome(200, width: 0), .cancel)
        XCTAssertEqual(outcome(200, width: -390), .cancel)
        XCTAssertEqual(outcome(200, width: .nan), .cancel)
        XCTAssertEqual(outcome(.nan, velocity: 2000), .cancel)
        XCTAssertEqual(outcome(.infinity, velocity: 2000), .cancel)
        XCTAssertEqual(outcome(200, vertical: .nan), .cancel)
        XCTAssertEqual(outcome(200, velocity: .nan), .cancel)
    }

    func testProgressFollowsTheFingerAndStaysInRange() {
        XCTAssertEqual(EdgeSwipeBackRule.progress(horizontal: 0, containerWidth: 400), 0)
        XCTAssertEqual(EdgeSwipeBackRule.progress(horizontal: 100, containerWidth: 400), 0.25, accuracy: 1e-9)
        XCTAssertEqual(EdgeSwipeBackRule.progress(horizontal: 400, containerWidth: 400), 1)
        XCTAssertEqual(EdgeSwipeBackRule.progress(horizontal: 900, containerWidth: 400), 1)
        XCTAssertEqual(EdgeSwipeBackRule.progress(horizontal: -50, containerWidth: 400), 0)
        XCTAssertEqual(EdgeSwipeBackRule.progress(horizontal: 100, containerWidth: 0), 0)
        XCTAssertEqual(EdgeSwipeBackRule.progress(horizontal: .nan, containerWidth: 400), 0)
    }

    func testCommitAgreesWithProgress() {
        // The release rule and what the screen showed can't disagree: a drag that has moved the
        // screen a third of the way (with no flick against it) commits.
        for horizontal in stride(from: 0.0, through: 390.0, by: 5.0) {
            let moved = EdgeSwipeBackRule.progress(horizontal: horizontal, containerWidth: width)
            let result = outcome(horizontal, velocity: 0)
            XCTAssertEqual(result == .commit, moved >= EdgeSwipeBackRule.commitFraction, "at \(horizontal) pt")
        }
    }
}
