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

    /// The check runs every 100 ms, so the same block lands at a different point of the cycle each time; the
    /// delays below walk it across the cycle.
    private let cyclePhases = [100, 130, 160, 190, 220, 250, 280, 310]

    func testAFourHundredMillisecondBlockRecordsOneHangWithItsLabel() {
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        defer { probe.stop() }
        for (round, phase) in cyclePhases.enumerated() {
            settle(phase)
            block(400, label: "refreshLibraryRows")
            settle(250)
            XCTAssertEqual(hangs.value.count, round + 1, "one hang per block (phase \(phase))")
            let hang = hangs.value.last
            XCTAssertTrue((330...550).contains(hang?.durationMs ?? 0), "was \(String(describing: hang?.durationMs)) (phase \(phase))")
            XCTAssertEqual(hang?.operation, "refreshLibraryRows")
        }
    }

    func testAThreeHundredFiftyMillisecondBlockIsStillRecorded() {
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        defer { probe.stop() }
        for (round, phase) in cyclePhases.enumerated() {
            settle(phase)
            block(350)
            settle(250)
            XCTAssertEqual(hangs.value.count, round + 1, "phase \(phase)")
        }
    }

    func testAHundredMillisecondBlockRecordsNothing() {
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        defer { probe.stop() }
        for phase in cyclePhases {
            settle(phase)
            block(100, label: "run")
        }
        settle(250)
        XCTAssertEqual(hangs.value, [])
    }

    func testNestedLabelsReadOutermostFirstAndAnUnlabelledHangHasNone() {
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
        XCTAssertEqual(hangs.value.map(\.operation), ["run>refreshSelectedItem", ""])
    }

    func testAStoppedProbeRecordsNothingAndASecondHangAfterAFirstIsCounted() {
        let hangs = Hangs()
        let probe = makeProbe(into: hangs)
        probe.start(intervalMs: 100)
        settle(100)
        block(350)
        settle(100)
        block(350)
        settle(100)
        XCTAssertEqual(hangs.value.count, 2)
        probe.stop()
        XCTAssertFalse(probe.isRunning)
        block(400)
        settle()
        XCTAssertEqual(hangs.value.count, 2)
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
