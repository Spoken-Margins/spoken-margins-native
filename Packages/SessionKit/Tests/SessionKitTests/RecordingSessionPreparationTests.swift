import Foundation
import XCTest
@testable import SessionKit

/// The ordering behind switching the audio session for a Margin off the main thread (#2511). A wrong answer here is
/// audible: a switch that lands after Cancel leaves the headphones on the hands-free profile with nothing recording,
/// and one that overlaps the recorder's own session calls can cut the microphone's route under it (#937 class).
final class RecordingSessionPreparationTests: XCTestCase {
    private struct Context: Sendable, Equatable { var route: String }

    /// Thread-safe log of what ran, and where.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var applyThreads: [Bool] = []
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
        func noteApplyOnMain(_ onMain: Bool) { lock.withLock { applyThreads.append(onMain) } }
        var all: [String] { lock.withLock { entries } }
        var applyRanOnMain: [Bool] { lock.withLock { applyThreads } }
    }

    func testSwitchRunsOffTheCallingThreadAndTheStartFollowsOnMain() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep")
        let log = Log()
        let started = expectation(description: "start runs")
        preparation.prepare(readContext: { Context(route: "A2DP") }, apply: { _ in
            log.noteApplyOnMain(Thread.isMainThread)
            log.add("apply")
            return true
        }, then: {
            log.add("then:\(Thread.isMainThread)")
            started.fulfill()
        })
        wait(for: [started], timeout: 5)
        XCTAssertEqual(log.applyRanOnMain, [false], "the session switch must not run on the main thread")
        XCTAssertEqual(log.all, ["apply", "then:true"], "the recorder starts on the main thread, after the switch")
        let claim = preparation.claim()
        XCTAssertEqual(claim?.context, Context(route: "A2DP"), "the recorder gets what was read before the switch")
        XCTAssertEqual(claim?.applied, true)
        XCTAssertNil(preparation.claim(), "a preparation is taken once")
        XCTAssertFalse(preparation.abandon(), "a claimed preparation is the recorder's: abandoning it lets nothing go")
    }

    func testCancelBeforeTheQueueReachesItMeansTheSwitchNeverRuns() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep")
        let log = Log()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        // A first tap's switch is running and holds the queue; a second tap queues behind it.
        preparation.prepare(readContext: { Context(route: "A2DP") }, apply: { _ in
            entered.signal()
            gate.wait()
            return false
        }, then: {})
        entered.wait()
        let started = expectation(description: "start still runs")
        preparation.prepare(readContext: { Context(route: "unused") }, apply: { _ in
            log.add("apply")
            return true
        }, then: { started.fulfill() })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.signal() }
        XCTAssertFalse(preparation.abandon(), "nothing changed the session, so nothing is let go")
        wait(for: [started], timeout: 5)
        XCTAssertEqual(log.all, [], "a switch cancelled before it started must never reach the audio session")
        XCTAssertNil(preparation.claim())
    }

    func testCancelAfterASecondTapStillLetsGoOfTheFirstTapsSwitch() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep")
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        preparation.prepare(readContext: { Context(route: "A2DP") }, apply: { _ in
            entered.signal()
            gate.wait()
            return true // the first tap's switch did change the session
        }, then: {})
        entered.wait()
        preparation.prepare(readContext: { Context(route: "unused") }, apply: { _ in true }, then: {})
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.signal() }
        XCTAssertTrue(preparation.abandon(),
                      "the superseded switch left the session on playAndRecord: Cancel must still let it go")
    }

    func testCancelDuringTheSwitchWaitsForItAndSaysToLetTheSessionGo() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep")
        let log = Log()
        let entered = DispatchSemaphore(value: 0)
        preparation.prepare(readContext: { Context(route: "A2DP") }, apply: { _ in
            entered.signal()
            Thread.sleep(forTimeInterval: 0.2) // the hands-free switch, in miniature
            log.add("apply done")
            return true
        }, then: {})
        entered.wait()
        let released = preparation.abandon()
        log.add("abandon returned")
        XCTAssertTrue(released, "the switch had changed the session, so Cancel must let it go")
        XCTAssertEqual(log.all, ["apply done", "abandon returned"],
                       "no session call from the switch may land after Cancel has let the session go")
        XCTAssertNil(preparation.claim())
    }

    func testRecorderStartWaitsForASwitchStillRunning() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep")
        let log = Log()
        let entered = DispatchSemaphore(value: 0)
        preparation.prepare(readContext: { Context(route: "A2DP") }, apply: { _ in
            entered.signal()
            Thread.sleep(forTimeInterval: 0.2)
            log.add("apply done")
            return true
        }, then: {})
        entered.wait()
        let claim = preparation.claim()
        log.add("claimed")
        XCTAssertEqual(log.all, ["apply done", "claimed"], "the recorder's own session calls must come after the switch")
        XCTAssertEqual(claim?.applied, true)
    }

    func testASecondTapKeepsWhatTheFirstReadBeforeItsSwitch() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep")
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        let log = Log()
        preparation.prepare(readContext: { Context(route: "A2DP") }, apply: { _ in log.add("apply"); return true }, then: { first.fulfill() })
        preparation.prepare(readContext: {
            XCTFail("the session was already being switched: reading it again would see the recording's route")
            return Context(route: "HFP")
        }, apply: { _ in log.add("apply"); return true }, then: { second.fulfill() })
        wait(for: [first, second], timeout: 5)
        XCTAssertEqual(preparation.claim()?.context, Context(route: "A2DP"))
    }

    func testAFailedSwitchStillStartsTheRecorderWhichThenSwitchesItself() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep")
        let started = expectation(description: "start runs")
        preparation.prepare(readContext: { Context(route: "A2DP") }, apply: { _ in false }, then: { started.fulfill() })
        wait(for: [started], timeout: 5)
        let claim = preparation.claim()
        XCTAssertEqual(claim?.applied, false)
        XCTAssertEqual(claim?.context, Context(route: "A2DP"))
    }

    func testNothingPreparedLeavesTheRecorderToReadTheSessionItself() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep")
        XCTAssertNil(preparation.claim())
        XCTAssertFalse(preparation.abandon())
        XCTAssertFalse(preparation.hasPending)
    }
}
