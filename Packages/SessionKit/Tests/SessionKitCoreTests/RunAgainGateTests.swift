import XCTest
@testable import SessionKit

/// #2136: Retry during a running import pass said "queued" and nothing ran; the followed-shows refresh dropped
/// requests the same way.
final class RunAgainGateTests: XCTestCase {
    func testAFreeGateGivesThePassToTheFirstRequestAndNoSecondRound() {
        var gate = RunAgainGate()
        XCTAssertTrue(gate.request())
        XCTAssertNil(gate.finishPass(), "nothing was asked for meanwhile")
        XCTAssertFalse(gate.isRunning)
    }

    func testARequestDuringAPassMakesExactlyOneMoreRound() {
        var gate = RunAgainGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request(), "the Retry tap while the pass runs is noted, not dropped")
        XCTAssertFalse(gate.request(), "a second tap in the same pass adds nothing")
        XCTAssertEqual(gate.finishPass(), false, "one more round")
        XCTAssertTrue(gate.isRunning, "the caller still holds the gate for that round")
        XCTAssertNil(gate.finishPass(), "and no round after it")
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.request(), "the gate is free for the next request")
    }

    func testAForcedRequestIsNotDowngradedByALaterUnforcedOne() {
        var gate = RunAgainGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request(forced: true)) // pull to refresh
        XCTAssertFalse(gate.request(forced: false)) // a background refresh right after
        XCTAssertEqual(gate.finishPass(), true)
    }

    func testARequestMadeDuringTheExtraRoundMakesAnotherRound() {
        var gate = RunAgainGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertEqual(gate.finishPass(), false)
        XCTAssertFalse(gate.request(forced: true), "asked for while the extra round runs")
        XCTAssertEqual(gate.finishPass(), true)
        XCTAssertNil(gate.finishPass())
    }

    func testTheForcedFlagDoesNotLeakIntoTheNextPass() {
        var gate = RunAgainGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request(forced: true))
        XCTAssertEqual(gate.finishPass(), true)
        XCTAssertNil(gate.finishPass())
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertEqual(gate.finishPass(), false, "the earlier forced request is spent")
    }
}
