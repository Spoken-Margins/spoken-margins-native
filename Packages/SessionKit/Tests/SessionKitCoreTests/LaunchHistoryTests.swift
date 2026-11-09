import Foundation
import XCTest
@testable import SessionKit

final class LaunchHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20Z

    private func finishedLaunch(_ history: inout LaunchHistory, at time: Date, readyMs: Int, items: Int = 398) {
        history.beginLaunch(at: time, build: "36", preInitMs: 180)
        history.mark(.rootAppear, elapsedMs: 420)
        history.mark(.libraryReady, elapsedMs: readyMs, libraryItems: items)
        history.mark(.usable, elapsedMs: readyMs + 14)
    }

    func testAFinishedLaunchReadsWithEachStageItsItemCountAndTheBuild() {
        var history = LaunchHistory()
        finishedLaunch(&history, at: start, readyMs: 1520)
        XCTAssertEqual(history.launchesLine, "09-21 14:13Z b36 pre 180ms root 420ms ready 1520ms n=398 usable 1534ms")
    }

    func testALaunchThatNeverReachedAUsableScreenIsFlaggedOnceAnotherLaunchFollows() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36", preInitMs: 200)
        history.mark(.rootAppear, elapsedMs: 300)
        XCTAssertFalse(history.launchesLine.contains("no_usable_screen"), "the newest launch may still be starting")

        finishedLaunch(&history, at: start.addingTimeInterval(600), readyMs: 900)
        let line = history.launchesLine
        XCTAssertTrue(line.hasPrefix("09-21 14:13Z b36 pre 200ms root 300ms no_usable_screen | "), line)
        XCTAssertFalse(line.hasSuffix("no_usable_screen"))
    }

    func testALaunchWithNoScreenIsNamedNoUiNotAKillAndGoesBeforeLaunchesThatHadOne() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36", preInitMs: 150) // a background refresh: no root view
        finishedLaunch(&history, at: start.addingTimeInterval(60), readyMs: 900)
        history.beginLaunch(at: start.addingTimeInterval(120), build: "36")
        XCTAssertTrue(history.launchesLine.hasPrefix("09-21 14:13Z b36 pre 150ms no_ui | "), history.launchesLine)

        // Background launches don't push the launches with a screen out of the list.
        var busy = LaunchHistory()
        finishedLaunch(&busy, at: start, readyMs: 1111)
        for index in 1...20 { busy.beginLaunch(at: start.addingTimeInterval(Double(index) * 60), build: "36") }
        XCTAssertEqual(busy.launches.count, LaunchHistory.launchCapacity)
        XCTAssertEqual(busy.launches.first?.libraryReadyMs, 1111, "the launch that showed a screen is still there")
    }

    func testAPrewarmedLaunchKeepsNoPreInitTimeAndSaysSo() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36", preInitMs: 2_400_000, prewarmed: true)
        history.mark(.rootAppear, elapsedMs: 250)
        XCTAssertNil(history.launches[0].preInitMs, "the gap before App.init was idle time")
        XCTAssertTrue(history.launchesLine.contains("prewarmed root 250ms"), history.launchesLine)
    }

    func testTheFirstUsableScreenCannotComeBeforeTheLibraryIsReady() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        history.mark(.usable, elapsedMs: 100)
        XCTAssertNil(history.launches[0].usableMs)
        history.mark(.libraryReady, elapsedMs: 300, libraryItems: 2)
        history.mark(.usable, elapsedMs: 340)
        XCTAssertEqual(history.launches[0].usableMs, 340)
    }

    func testTheKilledLaunchSurvivesTheRelaunchThroughTheSavedFile() throws {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        history.mark(.rootAppear, elapsedMs: 400)
        // The app is killed here; what was saved is what the next run reads.
        var next = try JSONDecoder().decode(LaunchHistory.self, from: JSONEncoder().encode(history))
        next.beginLaunch(at: start.addingTimeInterval(60), build: "36")
        XCTAssertEqual(next.launches.count, 2)
        XCTAssertNil(next.launches[0].usableMs)
        XCTAssertTrue(next.launchesLine.contains("root 400ms no_usable_screen"), next.launchesLine)
    }

    func testKeepsTheLastTenLaunchesNewestLast() {
        var history = LaunchHistory()
        for index in 0..<14 { finishedLaunch(&history, at: start.addingTimeInterval(Double(index) * 3600), readyMs: 1000 + index) }
        XCTAssertEqual(history.launches.count, 10)
        XCTAssertEqual(history.launches.first?.libraryReadyMs, 1004, "the four oldest are dropped")
        XCTAssertEqual(history.launches.last?.libraryReadyMs, 1013)
    }

    func testAStageKeepsItsFirstTimeAndANegativeTimeIsDropped() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        history.mark(.libraryReady, elapsedMs: 800, libraryItems: 5)
        history.mark(.usable, elapsedMs: 900)
        history.mark(.libraryReady, elapsedMs: 3000, libraryItems: 6) // a second bootstrap pass
        history.mark(.usable, elapsedMs: -5)
        XCTAssertEqual(history.launches[0].libraryReadyMs, 800)
        XCTAssertEqual(history.launches[0].libraryItems, 5)
        XCTAssertEqual(history.launches[0].usableMs, 900)
    }

    func testAMarkBeforeAnyLaunchChangesNothing() {
        var history = LaunchHistory()
        history.mark(.usable, elapsedMs: 10)
        history.mark(.rootAppear, elapsedMs: 10)
        XCTAssertEqual(history, LaunchHistory())
        XCTAssertEqual(history.launchesLine, "none")
        XCTAssertEqual(history.exitsLine, "none")
    }

    func testALibraryThatFailedToOpenIsShownInPlaceOfAReadyTime() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        history.mark(.libraryReady, elapsedMs: 500, libraryFailed: true)
        XCTAssertTrue(history.launchesLine.contains("library_failed"))
        XCTAssertNil(history.launches[0].libraryReadyMs)
    }

    // MARK: Exits

    func testAnExitKeepsItsReasonAndDetailSortedWithoutTheFieldsThatAreNoise() {
        var history = LaunchHistory()
        history.recordExit(fields: ["source": "metrickit", "reason": "crash", "delivery": "launch", "newReports": "1",
                                    "crashSignal": "SIGSEGV", "crashes": "1"], at: start)
        XCTAssertEqual(history.exitsLine, "09-21 14:13Z launch crash crashSignal=SIGSEGV,crashes=1")
    }

    func testWhenFullAnEmptyReportGoesBeforeAReportThatNamesACrash() {
        var history = LaunchHistory()
        history.recordExit(fields: ["reason": "crash", "crashes": "1"], at: start)
        for index in 1...LaunchHistory.exitCapacity + 3 {
            history.recordExit(fields: ["reason": "none_reported"], at: start.addingTimeInterval(Double(index) * 60))
        }
        XCTAssertEqual(history.exits.count, LaunchHistory.exitCapacity)
        XCTAssertEqual(history.exits.first?.reason, "crash", "the crash outlasts the empty reports")
        XCTAssertEqual(history.exits.filter { $0.reason == "none_reported" }.count, LaunchHistory.exitCapacity - 1)
    }

    func testWhenFullOfCrashesTheOldestGoes() {
        var history = LaunchHistory()
        for index in 0..<LaunchHistory.exitCapacity + 2 {
            history.recordExit(fields: ["reason": "crash", "crashes": String(index)], at: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(history.exits.count, LaunchHistory.exitCapacity)
        XCTAssertEqual(history.exits.first?.detail, "crashes=2")
    }

    func testFreeTextAndLongValuesNeverReachTheLines() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36 (Alice's phone)/secret")
        history.recordExit(fields: ["reason": "crash", "crashFrames": String(repeating: "0x1f,", count: 400),
                                    "note": "/Users/alice/Documents/Plan.pdf"], at: start)
        let lines = history.launchesLine + history.exitsLine
        XCTAssertFalse(lines.contains("/"))
        XCTAssertFalse(lines.contains("'"))
        XCTAssertLessThan(history.exits[0].detail.count, LaunchHistory.maxDetailLength + 5)
    }

    func testElapsedMillisecondsAreNilForAnUnknownStartOrABackwardsClock() {
        XCTAssertEqual(LaunchHistory.elapsedMs(from: start, to: start.addingTimeInterval(1.2345)), 1235)
        XCTAssertNil(LaunchHistory.elapsedMs(from: nil, to: start))
        XCTAssertNil(LaunchHistory.elapsedMs(from: start, to: start.addingTimeInterval(-1)))
        XCTAssertNil(LaunchHistory.elapsedMs(from: start, to: start.addingTimeInterval(200_000)), "a start from another day isn't this launch")
    }
}
