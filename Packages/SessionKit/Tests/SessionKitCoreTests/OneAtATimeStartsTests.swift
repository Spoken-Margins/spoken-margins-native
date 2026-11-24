import XCTest
@testable import SessionKit

/// The audit on #5124 (`e1eeb7c`, finding 2): with two episode maps held, Allow runs both retries in one turn. The second
/// found the preparer busy, warned "An episode map is already being prepared." and was lost.
final class OneAtATimeStartsTests: XCTestCase {
    func testTwoHeldRetriesInOneTurnBothStartOneAfterTheOther() {
        var starts = OneAtATimeStarts<String>()
        XCTAssertEqual(starts.offer("A", key: "a", isHeldRetry: true, busy: false), .start)
        XCTAssertEqual(starts.offer("B", key: "b", isHeldRetry: true, busy: true), .waitsItsTurn, "no warning, not dropped")
        XCTAssertNil(starts.next(busy: true), "nothing starts while A runs")
        XCTAssertEqual(starts.next(busy: false), "B", "B starts when A ends")
        XCTAssertNil(starts.next(busy: false))
    }

    func testTheListenersOwnRequestWhileBusyIsStillRefused() {
        var starts = OneAtATimeStarts<String>()
        XCTAssertEqual(starts.offer("B", key: "b", isHeldRetry: false, busy: true), .refuseBusy)
        XCTAssertNil(starts.next(busy: false), "a refused request does not start later")
    }

    func testWaitingRetriesKeepTheirOrderAndOnePlacePerKey() {
        var starts = OneAtATimeStarts<String>()
        _ = starts.offer("B1", key: "b", isHeldRetry: true, busy: true)
        _ = starts.offer("C", key: "c", isHeldRetry: true, busy: true)
        _ = starts.offer("B2", key: "b", isHeldRetry: true, busy: true)
        XCTAssertEqual(starts.waitingKeys, ["b", "c"])
        XCTAssertEqual(starts.next(busy: false), "B2", "the later retry for a key replaces the earlier, in its place")
        XCTAssertEqual(starts.next(busy: false), "C")
    }

    func testTheListenersRequestThatStartsCoversAWaitingRetryForTheSameKey() {
        var starts = OneAtATimeStarts<String>()
        _ = starts.offer("B", key: "b", isHeldRetry: true, busy: true)
        XCTAssertEqual(starts.offer("B tap", key: "b", isHeldRetry: false, busy: false), .start)
        XCTAssertEqual(starts.waitingKeys, [])
    }
}
