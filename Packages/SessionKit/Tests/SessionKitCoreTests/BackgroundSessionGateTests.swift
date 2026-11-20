import Foundation
import SessionKit
import XCTest

/// The launch crash behind #4392: CFNetwork aborts the app when a second background `URLSession` shares an
/// identifier with one that has not finished invalidating. `BackgroundSessionGate` is what makes the second
/// coordinator wait, so its rules are checked here on the host (#318) instead of through real background sessions.
@MainActor
final class BackgroundSessionGateTests: XCTestCase {
    func testGateHandsAnIdentifierToOneWaiterAtATimeAndTimesOut() async {
        let gate = BackgroundSessionGate()
        XCTAssertTrue(gate.claim("a"))
        XCTAssertFalse(gate.claim("a"), "a held identifier cannot be claimed twice")
        XCTAssertTrue(gate.claim("b"), "identifiers are independent")
        let timedOut = await gate.claim("a", waitingUpTo: .milliseconds(50))
        XCTAssertFalse(timedOut)

        // Generous deadlines: a stalled runner must not expire both waiters before the release.
        async let first = gate.claim("a", waitingUpTo: .seconds(1))
        async let second = gate.claim("a", waitingUpTo: .seconds(1))
        try? await Task.sleep(for: .milliseconds(30))
        gate.release("a")
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1, "only one waiter takes the identifier: \(results)")
        gate.release("never-held")   // harmless
    }

    func testAFreeIdentifierIsTakenAtOnceAndOnlyReleaseGivesItBack() async {
        let gate = BackgroundSessionGate()
        XCTAssertFalse(gate.isHeld("a"))
        let took = await gate.claim("a", waitingUpTo: .seconds(1))
        XCTAssertTrue(took, "nothing holds it, so there is nothing to wait for")
        XCTAssertTrue(gate.isHeld("a"))
        gate.release("a")
        XCTAssertFalse(gate.isHeld("a"))
        XCTAssertTrue(gate.claim("a"), "a released identifier can be claimed again")
    }

    /// An invalidation that ends the old session wakes the waiter at once, not when its timeout runs out. The waiter's
    /// own timeout is an hour, so it can only come back inside the 30 s ceiling if the release woke it; a gate that
    /// stopped waking waiters would re-claim the free identifier when the timeout ran out and still return true (#4573).
    func testAWaiterIsWokenByTheReleaseNotByItsTimeout() async {
        let gate = BackgroundSessionGate()
        XCTAssertTrue(gate.claim("a"))
        let woken = expectation(description: "the waiter came back after the release, long before its hour ran out")
        var took = false
        Task { @MainActor in
            took = await gate.claim("a", waitingUpTo: .seconds(3600))
            woken.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(30))
        gate.release("a")
        await fulfillment(of: [woken], timeout: 30)
        XCTAssertTrue(took, "woken by the release and took the identifier")
        XCTAssertTrue(gate.isHeld("a"), "the waiter now holds it")
    }

    /// Releasing one identifier must not hand over another that is still held.
    func testReleasingAnotherIdentifierDoesNotHandOverTheHeldOne() async {
        let gate = BackgroundSessionGate()
        XCTAssertTrue(gate.claim("a"))
        XCTAssertTrue(gate.claim("b"))
        async let waiting = gate.claim("a", waitingUpTo: .milliseconds(150))
        try? await Task.sleep(for: .milliseconds(20))
        gate.release("b")
        let took = await waiting
        XCTAssertFalse(took, "\"a\" was never released")
        XCTAssertTrue(gate.isHeld("a"))
    }

    /// A waiter that timed out is gone: a later release leaves the identifier free for the next claim instead of
    /// resuming a finished continuation or giving the identifier to nobody.
    func testATimedOutWaiterDoesNotTakeALaterRelease() async {
        let gate = BackgroundSessionGate()
        XCTAssertTrue(gate.claim("a"))
        let timedOut = await gate.claim("a", waitingUpTo: .milliseconds(30))
        XCTAssertFalse(timedOut)
        gate.release("a")
        XCTAssertFalse(gate.isHeld("a"), "no waiter was left behind to take it")
        XCTAssertTrue(gate.claim("a"))
    }

    /// Three coordinators queued on one identifier each get it in turn as the one before invalidates.
    func testQueuedWaitersEachTakeTheIdentifierInTurn() async {
        let gate = BackgroundSessionGate()
        XCTAssertTrue(gate.claim("a"))
        async let one = gate.claim("a", waitingUpTo: .seconds(10))
        async let two = gate.claim("a", waitingUpTo: .seconds(10))
        async let three = gate.claim("a", waitingUpTo: .seconds(10))
        // Release until all three have held it once; each release lets exactly one of those still waiting in.
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(40))
            gate.release("a")
        }
        let results = await [one, two, three]
        XCTAssertEqual(results, [true, true, true], "\(results)")
        XCTAssertTrue(gate.isHeld("a"), "the last waiter still holds it")
    }
}
