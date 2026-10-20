import Foundation
import XCTest
@testable import SessionKit

/// #2099: Build 35 recorded no main-thread stall in normal use. These watch a private serial queue standing in
/// for the main queue (the test's own main thread would not run the probe's blocks while the test waits).
/// The Done-when tests run at the app's own pace (250 ms threshold, a check every 100 ms; see `HangTelemetry`).
final class MainThreadHangProbeTests: XCTestCase {
    private let watched = DispatchQueue(label: "test.watched")
    private let labels = MainThreadOperationLabels()

    private final class Hangs: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [MainThreadHangProbe.Hang] = []
        func add(_ hang: MainThreadHangProbe.Hang) { lock.lock(); all.append(hang); lock.unlock() }
        var value: [MainThreadHangProbe.Hang] { lock.lock(); defer { lock.unlock() }; return all }
    }

    private func makeProbe(into hangs: Hangs, thresholdMs: Int = 250) -> MainThreadHangProbe {
        MainThreadHangProbe(thresholdMs: thresholdMs, watched: watched, labels: labels) { hangs.add($0) }
    }

    /// Blocks `watched` for `ms` (under `label` if given), then waits until the queue has run what came after.
    private func block(_ ms: Int, label: String? = nil) {
        let done = expectation(description: "block over")
        let labels = labels
        watched.async {
            if let label { labels.scoped(label) { usleep(UInt32(ms) * 1000) } } else { usleep(UInt32(ms) * 1000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    private func settle(_ ms: Int = 150) {
        let done = expectation(description: "settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// How late this host ran a 10 ms sleep, at worst, while a test was running (#2210). The probe measures the main
    /// queue against wall-clock time, so on a Mac under heavy load (load average above 40) its own timer fires late
    /// and every reading is off by more than the windows below allow, though the probe is right. Each timing test
    /// keeps its checks until it has seen how busy the host was: a busy host skips it, a calm one judges it.
    private final class SchedulerJitter: @unchecked Sendable {
        private let lock = NSLock()
        private var worstLateMs = 0.0
        private var running = true

        init() {
            let sampler = Thread { [self] in
                while isRunning {
                    let before = ProcessInfo.processInfo.systemUptime
                    usleep(10_000)
                    record((ProcessInfo.processInfo.systemUptime - before) * 1000 - 10)
                }
            }
            // Default quality of service, like the queues the probe is timed on: a busy host delays those most.
            sampler.start()
        }

        private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

        private func record(_ lateMs: Double) {
            lock.lock()
            worstLateMs = max(worstLateMs, lateMs)
            lock.unlock()
        }

        /// Stops sampling and returns the worst lateness seen, in milliseconds.
        func stop() -> Double {
            lock.lock()
            defer { lock.unlock() }
            running = false
            return worstLateMs
        }
    }

    private func startJitterSampling() -> SchedulerJitter {
        let jitter = SchedulerJitter()
        addTeardownBlock { _ = jitter.stop() }  // a test that ends early must not leave the sampler running
        return jitter
    }

    /// A 10 ms sleep that ran this much late means the probe's timer was just as late. The probe's duration
    /// windows below are about 70 ms wide on each side, so past this the verdict would say nothing about the probe.
    private static let busyHostLateMs = 40.0

    /// Skips the test if the host was too busy to judge it, else runs the checks it kept.
    private func conclude(_ jitter: SchedulerJitter, _ checks: [() -> Void]) throws {
        let late = jitter.stop()
        try XCTSkipIf(late > Self.busyHostLateMs, "the host ran a 10 ms sleep \(Int(late)) ms late, too busy to time the probe")
        for check in checks { check() }
    }

    /// The check runs every 100 ms, so the same block lands at a different point of the cycle each time; the
    /// delays below walk it across the cycle.
    private let cyclePhases = [100, 130, 160, 190, 220, 250, 280, 310]

    func testAFourHundredMillisecondBlockRecordsOneHangWithItsLabel() throws {
        let jitter = startJitterSampling()
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        defer { probe.stop() }
        var checks: [() -> Void] = []
        for (round, phase) in cyclePhases.enumerated() {
            settle(phase)
            block(400, label: "refreshLibraryRows")
            settle(250)
            let seen = hangs.value
            checks.append {
                XCTAssertEqual(seen.count, round + 1, "one hang per block (phase \(phase))")
                let hang = seen.last
                XCTAssertTrue((330...550).contains(hang?.durationMs ?? 0), "was \(String(describing: hang?.durationMs)) (phase \(phase))")
                XCTAssertEqual(hang?.operation, "refreshLibraryRows")
            }
        }
        try conclude(jitter, checks)
    }

    func testAThreeHundredFiftyMillisecondBlockIsStillRecorded() throws {
        let jitter = startJitterSampling()
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        defer { probe.stop() }
        var checks: [() -> Void] = []
        for (round, phase) in cyclePhases.enumerated() {
            settle(phase)
            block(350)
            settle(250)
            let count = hangs.value.count
            checks.append { XCTAssertEqual(count, round + 1, "phase \(phase)") }
        }
        try conclude(jitter, checks)
    }

    func testAHundredMillisecondBlockRecordsNothing() throws {
        let jitter = startJitterSampling()
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        defer { probe.stop() }
        for phase in cyclePhases {
            settle(phase)
            block(100, label: "run")
        }
        settle(250)
        let seen = hangs.value
        try conclude(jitter, [{ XCTAssertEqual(seen, []) }])
    }

    func testNestedLabelsReadOutermostFirstAndAnUnlabelledHangHasNone() throws {
        let jitter = startJitterSampling()
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        defer { probe.stop() }
        settle(100)
        let done = expectation(description: "block over")
        let labels = labels
        watched.async {
            labels.scoped("run") { labels.scoped("refreshSelectedItem") { usleep(400_000) } }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        block(400)
        settle()
        let operations = hangs.value.map(\.operation)
        try conclude(jitter, [{ XCTAssertEqual(operations, ["run>refreshSelectedItem", ""]) }])
    }

    func testAStoppedProbeRecordsNothingAndASecondHangAfterAFirstIsCounted() throws {
        let jitter = startJitterSampling()
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        settle(100)
        block(350)
        settle(100)
        block(350)
        settle(100)
        let beforeStop = hangs.value.count
        probe.stop()
        let stopped = probe.isRunning
        block(400)
        settle()
        let afterStop = hangs.value.count
        try conclude(jitter, [
            { XCTAssertEqual(beforeStop, 2) },
            { XCTAssertFalse(stopped) },
            { XCTAssertEqual(afterStop, 2) },
        ])
    }

    func testLabelStackIgnoresAnEntryAlreadyGoneAndKeepsTheOthers() {
        let stack = MainThreadOperationLabels()
        let outer = stack.push("run")
        let inner = stack.push("refreshLibraryRows")
        XCTAssertEqual(stack.current, "run>refreshLibraryRows")
        stack.pop(outer)
        XCTAssertEqual(stack.current, "refreshLibraryRows")
        stack.pop(outer)
        stack.pop(inner)
        XCTAssertEqual(stack.current, "")
    }

    /// Timer leeway is how far the system may postpone a check, and a late check widens the unknown stretch
    /// before a freeze. The Linux host never postpones, so the bound is asserted directly.
    func testTheTimersLeewayIsAtMostATenthOfItsInterval() {
        for interval in [10, 100, 250, 1000] {
            let leeway = MainThreadHangProbe.leewayMs(forInterval: interval)
            XCTAssertGreaterThanOrEqual(leeway, 1)
            XCTAssertLessThanOrEqual(leeway, max(1, interval / 10), "interval \(interval)")
        }
        XCTAssertEqual(MainThreadHangProbe.leewayMs(forInterval: 100), 10, "the app's pace")
    }
}
