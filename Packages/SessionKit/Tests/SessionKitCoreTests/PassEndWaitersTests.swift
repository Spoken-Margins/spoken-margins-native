import XCTest
@testable import SessionKit

/// #4955: a pull on Following made while a refresh runs waits for that refresh to end, so its spinner doesn't snap shut.
/// Every test waits on a count with a ceiling, never on a fixed sleep, so a broken end fails rather than hangs. They are async because Linux XCTest can't run a synchronous
/// main-actor test.
@MainActor
final class PassEndWaitersTests: XCTestCase {
    func testEveryWaiterReturnsWhenThePassEnds() async throws {
        let waiters = PassEndWaiters()
        let returned = Box()
        Task { @MainActor in await waiters.waitForEnd(); returned.count += 1 }
        Task { @MainActor in await waiters.waitForEnd(); returned.count += 1 }
        try await waitFor { waiters.waitingCount == 2 }
        XCTAssertEqual(waiters.waitingCount, 2)
        XCTAssertEqual(returned.count, 0, "nobody returns before the pass ends")

        waiters.passEnded()
        try await waitFor { returned.count == 2 }
        XCTAssertEqual(returned.count, 2, "both waiters returned after one end")
        XCTAssertEqual(waiters.waitingCount, 0)
    }

    func testAnEndWithNobodyWaitingIsHarmless() async {
        let waiters = PassEndWaiters()
        waiters.passEnded()
        waiters.passEnded()
        XCTAssertEqual(waiters.waitingCount, 0)
    }

    func testAWaiterThatStartsAfterAnEndWaitsForTheNextOne() async throws {
        let waiters = PassEndWaiters()
        waiters.passEnded()
        let returned = Box()
        Task { @MainActor in await waiters.waitForEnd(); returned.count += 1 }
        try await waitFor { waiters.waitingCount == 1 }
        XCTAssertEqual(waiters.waitingCount, 1)
        XCTAssertEqual(returned.count, 0, "an end that came before the wait doesn't count")

        waiters.passEnded()
        try await waitFor { returned.count == 1 }
        XCTAssertEqual(returned.count, 1, "the late waiter returned at the next end")
    }

    @MainActor private final class Box { var count = 0 }

    /// Polls a condition with a ceiling, never a fixed sleep before an assert.
    private func waitFor(ceiling: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: ceiling)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
