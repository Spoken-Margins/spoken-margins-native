import XCTest
@testable import SessionKit

/// #2099: in-app taps leave no record, so a tap that waits for its work can't be told from one that never landed.
final class TapToStateTrackerTests: XCTestCase {
    func testTheFirstStatusChangeAfterATapGivesItsDelay() {
        var tracker = TapToStateTracker()
        tracker.tapped(command: "togglePlayPause", status: "playing", at: 100.0)
        XCTAssertNil(tracker.statusChanged(to: "playing", at: 100.1), "the same status is not an answer")
        let fields = tracker.statusChanged(to: "paused", at: 100.35)
        XCTAssertEqual(fields, ["command": "togglePlayPause", "from": "playing", "to": "paused", "tapToStateMs": "350"])
        XCTAssertNil(tracker.statusChanged(to: "playing", at: 101), "one answer per tap")
        XCTAssertNil(tracker.pending)
    }

    func testAStatusChangeWithNoTapWaitingIsNotATapAnswer() {
        var tracker = TapToStateTracker()
        XCTAssertNil(tracker.statusChanged(to: "paused", at: 5))
    }

    func testANewerTapReplacesAnOlderOne() {
        var tracker = TapToStateTracker()
        tracker.tapped(command: "play", status: "paused", at: 10)
        tracker.tapped(command: "pause", status: "starting", at: 12)
        let fields = tracker.statusChanged(to: "paused", at: 12.2)
        XCTAssertEqual(fields?["command"], "pause")
        XCTAssertEqual(fields?["tapToStateMs"], "200")
    }

    func testAChangeLongAfterTheTapIsNotBlamedOnIt() {
        var tracker = TapToStateTracker()
        tracker.tapped(command: "play", status: "paused", at: 10)
        XCTAssertNil(tracker.statusChanged(to: "playing", at: 10 + TapToStateTracker.windowSeconds + 1))
        XCTAssertNil(tracker.pending, "and the stale tap is dropped")
    }

    func testASlowStartStillCountsInsideTheWindow() {
        var tracker = TapToStateTracker()
        tracker.tapped(command: "togglePlayPause", status: "paused", at: 0)
        XCTAssertEqual(tracker.statusChanged(to: "starting", at: 8.0)?["tapToStateMs"], "8000")
    }
}
