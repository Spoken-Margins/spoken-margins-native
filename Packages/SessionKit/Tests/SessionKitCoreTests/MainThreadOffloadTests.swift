import Foundation
import XCTest
@testable import SessionKit

/// #2967: a play tap froze the app for 4.3 s with no operation named. The audio-session activation and the ActivityKit
/// permission check in that path wait on system daemons, so they run through these two types instead of on the main
/// thread. The tests use a slow call as the daemon: the caller must come back at once, and a stale request must not run.
final class MainThreadOffloadTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testSubmitReturnsWhileTheSlowCallIsStillRunning() {
        let work = LatestOnlyBackgroundWork(label: "test.offload.slow")
        let started = expectation(description: "slow call started")
        let release = DispatchSemaphore(value: 0)
        let log = Log()
        let submitted = Date()
        work.submit {
            started.fulfill()
            release.wait()
            log.add("done")
        }
        XCTAssertLessThan(Date().timeIntervalSince(submitted), 0.2, "the caller never waits for the call")
        wait(for: [started], timeout: 2)
        XCTAssertEqual(log.all, [], "the call is still blocked on the daemon")
        release.signal()
        work.waitUntilIdle()
        XCTAssertEqual(log.all, ["done"])
    }

    func testOnlyTheNewestWaitingRequestRuns() {
        let work = LatestOnlyBackgroundWork(label: "test.offload.latest")
        let started = expectation(description: "first started")
        let release = DispatchSemaphore(value: 0)
        let log = Log()
        work.submit { started.fulfill(); release.wait(); log.add("first") }
        wait(for: [started], timeout: 2)
        work.submit { log.add("second") }
        work.submit { log.add("third") }
        release.signal()
        work.waitUntilIdle()
        XCTAssertEqual(log.all, ["first", "third"], "the second was replaced before the queue reached it")
    }

    func testCancelPendingDropsARequestThatHasNotStarted() {
        let work = LatestOnlyBackgroundWork(label: "test.offload.cancel")
        let started = expectation(description: "first started")
        let release = DispatchSemaphore(value: 0)
        let log = Log()
        work.submit { started.fulfill(); release.wait(); log.add("first") }
        wait(for: [started], timeout: 2)
        work.submit { log.add("activate after the pause") }
        work.cancelPending() // the pause that made it stale
        release.signal()
        work.waitUntilIdle()
        XCTAssertEqual(log.all, ["first"])
    }

    func testFlagReadNeverWaitsForTheSlowRead() {
        let release = DispatchSemaphore(value: 0)
        let flag = RefreshedSystemFlag(initial: true, maxAge: 5, label: "test.flag.slow") {
            release.wait()
            return false
        }
        let began = Date()
        XCTAssertTrue(flag.value, "before the first answer the flag reads its initial value")
        XCTAssertTrue(flag.value, "and again while that first read is still blocked")
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.2)
        release.signal()
        flag.waitUntilIdle()
        XCTAssertFalse(flag.value, "the background read replaced the answer")
    }

    func testFlagRereadsOnlyOnceItIsOlderThanMaxAge() {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
        let clock = Clock()
        let reads = Log()
        let flag = RefreshedSystemFlag(initial: false, maxAge: 5, label: "test.flag.age", clock: { clock.now }) {
            reads.add("read")
            return true
        }
        _ = flag.value
        flag.waitUntilIdle()
        XCTAssertEqual(reads.all.count, 1)
        clock.now += 4
        _ = flag.value
        flag.waitUntilIdle()
        XCTAssertEqual(reads.all.count, 1, "a young answer is not read again")
        clock.now += 2
        XCTAssertTrue(flag.value)
        flag.waitUntilIdle()
        XCTAssertEqual(reads.all.count, 2, "an answer past maxAge starts one more read")
    }
}
