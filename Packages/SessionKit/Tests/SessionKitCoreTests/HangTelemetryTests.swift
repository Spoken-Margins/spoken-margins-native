import Foundation
import XCTest
@testable import SessionKit

/// #2099 / #318: what the app keeps in Diagnostics about a freeze or a slow tap. These ran only in the app-hosted
/// simulator suite, where the rate limit on `main.hang` records was not covered at all. A test clock stands in
/// for the system uptime, and `handle` stands in for the probe's report, so nothing waits on a real stall.
final class HangTelemetryTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval
        init(_ start: TimeInterval) { seconds = start }
        var now: TimeInterval {
            get { lock.lock(); defer { lock.unlock() }; return seconds }
            set { lock.lock(); defer { lock.unlock() }; seconds = newValue }
        }
    }

    private struct Written { let kind: String; let fields: [String: String] }

    private let clock = Clock(10_000)
    @MainActor private lazy var telemetry = HangTelemetry(clock: { [clock] in clock.now })
    @MainActor private var written: [Written] = []
    @MainActor private var contextCalls = 0

    @MainActor private func report(_ hang: MainThreadHangProbe.Hang) {
        telemetry.handle(
            hang,
            record: { [unowned self] kind, fields in written.append(Written(kind: kind, fields: fields)) },
            context: { [unowned self] in contextCalls += 1; return ["screen": "item", "status": "playing"] }
        )
    }

    private func hang(_ ms: Int = 300, operation: String = "run") -> MainThreadHangProbe.Hang {
        MainThreadHangProbe.Hang(durationMs: ms, operation: operation)
    }

    // MARK: The record

    @MainActor func testAHangIsWrittenWithItsContextDurationAndOperation() async {
        report(hang(420, operation: "refreshLibraryRows"))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.kind, "main.hang")
        XCTAssertEqual(written.first?.fields["screen"], "item")
        XCTAssertEqual(written.first?.fields["status"], "playing")
        XCTAssertEqual(written.first?.fields["durationMs"], "420")
        XCTAssertEqual(written.first?.fields["operation"], "refreshLibraryRows")
        XCTAssertNil(written.first?.fields["operationSamples"], "no samples, no field")
        XCTAssertNil(written.first?.fields["skipped"])
    }

    @MainActor func testAHangWithNoLabelSaysNone() async {
        report(hang(operation: ""))
        XCTAssertEqual(written.first?.fields["operation"], "none")
    }

    @MainActor func testTheStallsSamplesAreWritten() async {
        report(MainThreadHangProbe.Hang(
            durationMs: 900, operation: "b",
            samples: [.init(label: "a", count: 3), .init(label: "b", count: 1)]
        ))
        XCTAssertEqual(written.first?.fields["operationSamples"], "a=3;b=1")
    }

    @MainActor func testTheLastTapRidesAlongWithTheHang() async {
        telemetry.noteTap(command: "togglePlayPause", status: "paused")
        clock.now += 2.5
        report(hang())
        XCTAssertEqual(written.first?.fields["lastTap"], "togglePlayPause")
        XCTAssertEqual(written.first?.fields["lastTapAgoMs"], "2500")
    }

    // MARK: The allowance

    @MainActor func testOnlyTheFirstTwentyHangsInAWindowAreWrittenAndTheRestAreCounted() async {
        let limit = HangTelemetry.maxHangRecordsPerWindow
        for _ in 0..<(limit + 5) { report(hang()) }
        XCTAssertEqual(written.count, limit)
        XCTAssertEqual(contextCalls, limit, "a hang left out costs no context read")
        XCTAssertTrue(written.allSatisfy { $0.fields["skipped"] == nil })

        clock.now += HangTelemetry.hangWindowSeconds + 1
        report(hang())
        XCTAssertEqual(written.count, limit + 1)
        XCTAssertEqual(written.last?.fields["skipped"], "5", "the next record says how many were left out")

        report(hang())
        XCTAssertNil(written.last?.fields["skipped"], "and says it once")
    }

    @MainActor func testTheWindowDoesNotReopenAtExactlyItsLength() async {
        let limit = HangTelemetry.maxHangRecordsPerWindow
        report(hang()) // opens a window at the current clock
        for _ in 1..<limit { report(hang()) }
        clock.now += HangTelemetry.hangWindowSeconds // exactly the window, not past it
        report(hang())
        XCTAssertEqual(written.count, limit, "the window is still the same one")
        clock.now += 0.001
        report(hang())
        XCTAssertEqual(written.count, limit + 1)
        XCTAssertEqual(written.last?.fields["skipped"], "1")
    }

    @MainActor func testAHangAfterAQuietStretchStartsAFreshAllowance() async {
        for _ in 0..<HangTelemetry.maxHangRecordsPerWindow { report(hang()) }
        clock.now += HangTelemetry.hangWindowSeconds * 3
        for _ in 0..<HangTelemetry.maxHangRecordsPerWindow { report(hang()) }
        XCTAssertEqual(written.count, HangTelemetry.maxHangRecordsPerWindow * 2)
    }

    // MARK: Taps

    @MainActor func testNoTapReadsNone() async {
        XCTAssertEqual(telemetry.lastTapFields(), ["lastTap": "none"])
    }

    @MainActor func testTheLastTapIsReportedForAMinuteAndThenForgotten() async {
        telemetry.noteTap(command: "togglePlayPause", status: "paused")
        clock.now += 59.9
        XCTAssertEqual(telemetry.lastTapFields()["lastTap"], "togglePlayPause")
        clock.now += 0.2 // 60.1 s
        XCTAssertEqual(telemetry.lastTapFields(), ["lastTap": "none"])
    }

    @MainActor func testANewerTapReplacesTheLastOne() async {
        telemetry.noteTap(command: "togglePlayPause", status: "paused")
        clock.now += 1
        telemetry.noteTap(command: "restartFinished", status: "finished")
        clock.now += 1
        XCTAssertEqual(telemetry.lastTapFields()["lastTap"], "restartFinished")
        XCTAssertEqual(telemetry.lastTapFields()["lastTapAgoMs"], "1000")
    }

    @MainActor func testAStatusChangeAfterATapIsLoggedWithItsDelay() async {
        telemetry.noteTap(command: "togglePlayPause", status: "paused")
        clock.now += 0.4
        let answer = telemetry.statusChanged(to: "playing")
        XCTAssertEqual(answer?["from"], "paused")
        XCTAssertEqual(answer?["to"], "playing")
        XCTAssertEqual(answer?["tapToStateMs"], "400")
        XCTAssertNil(telemetry.statusChanged(to: "paused"), "one answer per tap")
    }

    // MARK: Closing the mini player

    @MainActor func testTheCloseWaitIsReadOnceInMilliseconds() async {
        XCTAssertNil(telemetry.takeCloseElapsedMs(), "no close waits")
        telemetry.closeTapped()
        clock.now += 0.75
        XCTAssertEqual(telemetry.takeCloseElapsedMs(), 750)
        XCTAssertNil(telemetry.takeCloseElapsedMs(), "once")
    }
}
