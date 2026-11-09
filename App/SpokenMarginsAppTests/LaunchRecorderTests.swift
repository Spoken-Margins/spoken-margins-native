import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #3752: the owner's export had no launch time, and the launches of the day before had fallen off the
/// 300-event log. The history is kept in `UserDefaults`, so these tests use a throwaway suite.
@MainActor
final class LaunchRecorderTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var lines: [String: String] = [:]

    override func setUp() {
        super.setUp()
        suiteName = "launch-recorder-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        lines = [:]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// `processStart` is when the kernel made the process; `App.init` runs at `clock` when this is called.
    private func makeRecorder(processStart: Date? = nil, build: String = "36") -> LaunchRecorder {
        let recorder = LaunchRecorder(defaults: defaults, build: build, processStart: processStart ?? clock, now: { [unowned self] in clock },
                                      runSoon: { work in work() })
        recorder.attach { [unowned self] key, value in lines[key] = value }
        return recorder
    }

    func testEachStageIsTimedFromAppInitAndPublishedAsADiagnosticsLine() {
        let start = clock
        let recorder = makeRecorder(processStart: start.addingTimeInterval(-0.2))
        clock = start.addingTimeInterval(0.3); recorder.markRootAppeared()
        clock = start.addingTimeInterval(1.4); recorder.markLibraryReady(items: 398)
        XCTAssertNil(recorder.history.launches.last?.usableMs, "ready is not yet shown")
        clock = start.addingTimeInterval(1.5); recorder.markLibraryShown()

        XCTAssertEqual(recorder.history.launches.last?.preInitMs, 200)
        XCTAssertEqual(recorder.history.launches.last?.rootAppearMs, 300)
        XCTAssertEqual(recorder.history.launches.last?.libraryReadyMs, 1400)
        XCTAssertEqual(recorder.history.launches.last?.usableMs, 1500)
        XCTAssertEqual(lines[LaunchRecorder.launchesKey], "09-21 14:13Z b36 pre 200ms root 300ms ready 1400ms n=398 usable 1500ms")
    }

    func testAnEmptyLibraryIsUsableOnTheNextTurnBecauseNothingTheRootViewWatchesChanges() {
        let recorder = makeRecorder()
        clock = clock.addingTimeInterval(0.4); recorder.markLibraryReady(items: 0)
        XCTAssertEqual(recorder.history.launches.last?.usableMs, 400)
    }

    func testAProcessStartedLongBeforeAppInitIsAPrewarmAndItsIdleGapIsNotATime() {
        let start = clock
        let recorder = makeRecorder(processStart: start.addingTimeInterval(-2400)) // started 40 minutes earlier
        clock = start.addingTimeInterval(0.3); recorder.markRootAppeared()
        XCTAssertNil(recorder.history.launches.last?.preInitMs)
        XCTAssertEqual(recorder.history.launches.last?.prewarmed, true)
        XCTAssertEqual(recorder.history.launches.last?.rootAppearMs, 300, "measured from App.init, not the kernel's start")
    }

    func testALaunchKilledBeforeTheLibraryShowedIsReportedByTheNextRun() {
        let first = clock
        let killed = makeRecorder()
        clock = first.addingTimeInterval(0.4); killed.markRootAppeared() // then the app is killed

        clock = first.addingTimeInterval(300)
        let relaunch = makeRecorder()
        XCTAssertEqual(relaunch.history.launches.count, 2)
        XCTAssertTrue(lines[LaunchRecorder.launchesKey]?.contains("root 400ms no_usable_screen") == true, lines[LaunchRecorder.launchesKey] ?? "no line")
    }

    func testAnExitRecordIsKeptAcrossLaunchesAndPublished() {
        let recorder = makeRecorder()
        recorder.noteExit(fields: ["source": "metrickit", "reason": "crash", "delivery": "launch", "crashes": "1", "newReports": "1"])
        XCTAssertEqual(lines[LaunchRecorder.exitsKey], "09-21 14:13Z launch crash crashes=1")

        clock = clock.addingTimeInterval(3600)
        _ = makeRecorder()
        XCTAssertEqual(lines[LaunchRecorder.exitsKey], "09-21 14:13Z launch crash crashes=1", "shown from the first moment of the next run")
    }

    func testAnUnknownProcessStartLeavesOutOnlyThePreInitTime() {
        let recorder = LaunchRecorder(defaults: defaults, build: "36", processStart: nil, now: { [unowned self] in clock },
                                      runSoon: { work in work() })
        clock = clock.addingTimeInterval(0.25); recorder.markRootAppeared()
        recorder.markLibraryReady(items: 3)
        XCTAssertNil(recorder.history.launches.last?.preInitMs)
        XCTAssertNotEqual(recorder.history.launches.last?.prewarmed, true)
        XCTAssertEqual(recorder.history.launches.last?.rootAppearMs, 250, "marks run from App.init, which is known")
        XCTAssertEqual(recorder.history.launches.count, 1)
    }

    func testTheKernelGivesAProcessStartJustBeforeNow() throws {
        let start = try XCTUnwrap(LaunchRecorder.currentProcessStart())
        let elapsed = try XCTUnwrap(LaunchHistory.elapsedMs(from: start, to: Date()))
        XCTAssertGreaterThanOrEqual(elapsed, 0)
        XCTAssertLessThan(elapsed, 86_400_000)
    }
}
