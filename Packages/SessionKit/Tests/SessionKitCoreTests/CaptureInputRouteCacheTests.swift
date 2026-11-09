import Foundation
import XCTest
@testable import SessionKit

/// #2511: the capture poll read `AVAudioSession.currentRoute` on the main thread every 50 ms while Bluetooth headphones
/// settled into the hands-free profile. The poll now reads a cache; the read itself runs off the main thread.
final class CaptureInputRouteCacheTests: XCTestCase {
    private func makeCache() -> CaptureInputRouteCache { CaptureInputRouteCache(label: "test.input-route-cache") }

    func testNothingIsKnownBeforeTheFirstReadLands() {
        XCTAssertNil(makeCache().value)
    }

    func testARefreshReadsOffTheCallingThreadAndKeepsTheAnswer() {
        let cache = makeCache()
        let readOnMain = LockedFlag()
        cache.refreshOffMain {
            if Thread.isMainThread { readOnMain.set() }
            return "BluetoothHFP"
        }
        cache.waitUntilIdle()
        XCTAssertEqual(cache.value, "BluetoothHFP")
        XCTAssertFalse(readOnMain.isSet, "the route is read on the cache's queue, never on the thread that asked")
    }

    /// The bug: a read that waits on the audio server held every poll behind it. The poll's read is `value`.
    func testASlowReadNeverHoldsThePollThatReadsTheValue() {
        let cache = makeCache()
        cache.set("BuiltInMic")
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        cache.refreshOffMain {
            started.signal()
            release.wait() // the audio server is busy with the route change
            return "BluetoothHFP"
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)

        let begin = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { XCTAssertEqual(cache.value, "BuiltInMic", "the poll sees the last answer while the read waits") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 1, "100 polls did not wait for the read")

        release.signal()
        cache.waitUntilIdle()
        XCTAssertEqual(cache.value, "BluetoothHFP")
    }

    func testANewerRefreshWinsOverAnOlderOneStillRunning() {
        let cache = makeCache()
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        cache.refreshOffMain {
            started.signal()
            release.wait()
            return "older"
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        cache.refreshOffMain { "newer" } // queued behind the first on the serial queue
        release.signal()
        cache.waitUntilIdle()
        XCTAssertEqual(cache.value, "newer")
    }

    func testASetMadeWhileAReadRunsIsNotOverwrittenByIt() {
        let cache = makeCache()
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        cache.refreshOffMain {
            started.signal()
            release.wait()
            return "read before the switch"
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        cache.set("read after the switch")
        release.signal()
        cache.waitUntilIdle()
        XCTAssertEqual(cache.value, "read after the switch")
    }

    func testAClearMadeWhileAReadRunsDropsItsAnswer() {
        let cache = makeCache()
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        cache.refreshOffMain {
            started.signal()
            release.wait()
            return "the last Margin's route"
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        cache.clear() // the next Margin began
        release.signal()
        cache.waitUntilIdle()
        XCTAssertNil(cache.value, "a new Margin never shows the route of the one before it")
    }

    func testAReadThatFindsNoRouteClearsTheOldAnswer() {
        let cache = makeCache()
        cache.set("BluetoothHFP")
        cache.refreshOffMain { nil } // the headphones went away
        cache.waitUntilIdle()
        XCTAssertNil(cache.value)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var isSet: Bool { lock.withLock { flag } }
}
