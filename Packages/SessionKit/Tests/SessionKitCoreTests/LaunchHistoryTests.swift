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

    /// #4388: the export shows the time from launch to Following up to date, and whether only its first screen was refreshed.
    func testTheTimeFromLaunchToFollowingUpToDateIsReadAndKeepsItsFirstValue() throws {
        var history = LaunchHistory()
        finishedLaunch(&history, at: start, readyMs: 1520)
        history.mark(.followingFresh, elapsedMs: 4200)
        history.mark(.followingFresh, elapsedMs: 9000, firstScreenOnly: true)
        XCTAssertEqual(history.launchesLine, "09-21 14:13Z b36 pre 180ms root 420ms ready 1520ms n=398 usable 1534ms following_fresh 4200ms")

        var lowPower = LaunchHistory()
        finishedLaunch(&lowPower, at: start, readyMs: 1520)
        lowPower.mark(.followingFresh, elapsedMs: 2600, firstScreenOnly: true)
        XCTAssertTrue(lowPower.launchesLine.hasSuffix("following_fresh 2600ms first_screen_only"), lowPower.launchesLine)

        let reread = try JSONDecoder().decode(LaunchHistory.self, from: JSONEncoder().encode(lowPower))
        XCTAssertEqual(reread, lowPower)
        let older = #"{"launches":[{"startedAt":0,"build":"36","usableMs":10}],"exits":[]}"#
        XCTAssertNoThrow(try JSONDecoder().decode(LaunchHistory.self, from: Data(older.utf8)), "a history saved before this field still reads")
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

    // MARK: Main-thread stalls in a launch (#3752)

    /// The owner's 19 s cold launch had totals and no phases. A stall that ends in the first minute is kept with the launch.
    func testAStallInTheLaunchesFirstMinuteIsKeptWithWhenItBeganHowLongAndWhere() {
        var history = LaunchHistory()
        finishedLaunch(&history, at: start, readyMs: 1520)
        history.noteHang(elapsedMs: 3900, durationMs: 2421, operation: "start.offlineAssets")
        XCTAssertEqual(history.launches[0].hangs, [LaunchHistory.Hang(atMs: 1479, durationMs: 2421, operation: "start.offlineAssets", samples: nil)])
        XCTAssertEqual(history.launchesLine,
                       "09-21 14:13Z b36 pre 180ms root 420ms ready 1520ms n=398 usable 1534ms hangs 1 total 2421ms [2421ms@1479 start.offlineAssets]")
    }

    func testALaunchWithNoStallReadsAsBeforeAndTheSamplesRideAlong() {
        var history = LaunchHistory()
        finishedLaunch(&history, at: start, readyMs: 1520)
        XCTAssertFalse(history.launchesLine.contains("hangs"))
        history.noteHang(elapsedMs: 19_000, durationMs: 18_000, operation: "launch.bootstrapLibrary>refreshLibraryRows",
                         samples: "launch.bootstrapLibrary=150;refreshLibraryRows=30")
        XCTAssertTrue(history.launchesLine.hasSuffix(
            "hangs 1 total 18000ms [18000ms@1000 launch.bootstrapLibrary>refreshLibraryRows (launch.bootstrapLibrary=150;refreshLibraryRows=30)]"),
                      history.launchesLine)
    }

    /// Neighbouring inputs: edges of the window, empty and odd durations, clock oddities, no launch yet.
    func testWhichStallsBelongToTheLaunch() {
        func line(elapsedMs: Int, durationMs: Int, operation: String = "run") -> LaunchHistory {
            var history = LaunchHistory()
            history.beginLaunch(at: start, build: "36")
            history.noteHang(elapsedMs: elapsedMs, durationMs: durationMs, operation: operation)
            return history
        }
        XCTAssertEqual(line(elapsedMs: LaunchHistory.hangWindowMs + 300, durationMs: 300).launches[0].hangCount, 1, "beginning at the window's edge counts")
        XCTAssertNil(line(elapsedMs: LaunchHistory.hangWindowMs + 301, durationMs: 300).launches[0].hangCount, "beginning after it belongs to the session")
        XCTAssertEqual(line(elapsedMs: 95_000, durationMs: 90_000).launches[0].hangs?.first?.atMs, 5000, "a long stall that began early counts even though it ended late")
        XCTAssertNil(line(elapsedMs: -1, durationMs: 300).launches[0].hangCount, "a clock that went backwards")
        XCTAssertNil(line(elapsedMs: 500, durationMs: 0).launches[0].hangCount)
        XCTAssertNil(line(elapsedMs: 500, durationMs: -40).launches[0].hangCount)
        XCTAssertEqual(line(elapsedMs: 100, durationMs: 900).launches[0].hangs?.first?.atMs, 0, "a stall that began before App.init starts at 0")
        XCTAssertEqual(line(elapsedMs: 500, durationMs: 300, operation: "").launches[0].hangs?.first?.operation, "none")
        var nothingYet = LaunchHistory()
        nothingYet.noteHang(elapsedMs: 500, durationMs: 300, operation: "run")
        XCTAssertEqual(nothingYet, LaunchHistory(), "no launch to belong to")
    }

    func testEveryStallIsCountedButOnlyTheLongestFiveKeepDetailsInTimeOrder() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        let lengths = [300, 900, 260, 700, 2000, 280, 500]
        for (index, length) in lengths.enumerated() {
            history.noteHang(elapsedMs: 2000 + index * 3000, durationMs: length, operation: "op\(index)")
        }
        XCTAssertEqual(history.launches[0].hangCount, 7)
        XCTAssertEqual(history.launches[0].hangTotalMs, lengths.reduce(0, +))
        XCTAssertEqual(history.launches[0].hangs?.map(\.operation), ["op0", "op1", "op3", "op4", "op6"])
        XCTAssertEqual(history.launches[0].hangs?.map(\.atMs), [1700, 4100, 10_300, 12_000, 19_500])
    }

    func testEqualStallsKeepTheEarlierOnesWhenFull() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        for index in 0..<(LaunchHistory.maxHangsPerLaunch + 2) {
            history.noteHang(elapsedMs: 1000 + index * 1000, durationMs: 300, operation: "op\(index)")
        }
        XCTAssertEqual(history.launches[0].hangs?.map(\.operation), ["op0", "op1", "op2", "op3", "op4"])
    }

    func testAStallBelongsToTheNewestLaunchOnly() {
        var history = LaunchHistory()
        finishedLaunch(&history, at: start, readyMs: 900)
        history.beginLaunch(at: start.addingTimeInterval(60), build: "36")
        history.noteHang(elapsedMs: 800, durationMs: 400, operation: "run")
        XCTAssertNil(history.launches[0].hangCount)
        XCTAssertEqual(history.launches[1].hangCount, 1)
    }

    func testAStallLabelIsPlainAndShortAndNeverCarriesFreeText() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        history.noteHang(elapsedMs: 1000, durationMs: 400, operation: "open /Users/alice/Plan.pdf | x",
                         samples: String(repeating: "a=1;", count: 100))
        let hang = history.launches[0].hangs![0]
        XCTAssertFalse(hang.operation.contains("/"))
        XCTAssertFalse(hang.operation.contains("|"))
        XCTAssertLessThanOrEqual(hang.samples!.count, LaunchHistory.maxHangLabelLength)
        XCTAssertEqual(history.launchesLine.components(separatedBy: " | ").count, 1, "a label can't fake a launch separator")
        XCTAssertFalse(hang.samples!.hasSuffix(";"))
        XCTAssertFalse(hang.samples!.hasSuffix("="))
    }

    func testATooLongOperationKeepsItsInnermostLabelAndTheSamplesKeepWholePairs() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        let stack = (1...5).map { "outerLabelNumber\($0)_0123456789012" }.joined(separator: ">") + ">start.offlineAssets"
        let samples = (1...12).map { "label\($0)_01234567890123=\($0)" }.joined(separator: ";")
        history.noteHang(elapsedMs: 1000, durationMs: 400, operation: stack, samples: samples)
        let hang = history.launches[0].hangs![0]
        XCTAssertTrue(hang.operation.hasSuffix(">start.offlineAssets"), hang.operation)
        XCTAssertLessThanOrEqual(hang.operation.count, LaunchHistory.maxHangLabelLength)
        XCTAssertLessThanOrEqual(hang.samples!.count, LaunchHistory.maxHangLabelLength)
        XCTAssertTrue(hang.samples!.split(separator: ";").allSatisfy { $0.contains("=") && $0.last != "=" }, hang.samples!)
    }

    func testNoteHangSaysWhetherItTookTheStall() {
        var history = LaunchHistory()
        history.beginLaunch(at: start, build: "36")
        XCTAssertTrue(history.noteHang(elapsedMs: 1000, durationMs: 400, operation: "run"))
        XCTAssertFalse(history.noteHang(elapsedMs: 200_000, durationMs: 400, operation: "run"))
        XCTAssertFalse(history.noteHang(elapsedMs: 1000, durationMs: 0, operation: "run"))
    }

    func testStallsSurviveTheSavedFileAndAnOlderFileStillReads() throws {
        var history = LaunchHistory()
        finishedLaunch(&history, at: start, readyMs: 900)
        history.noteHang(elapsedMs: 2000, durationMs: 700, operation: "run", samples: "run=3")
        let reread = try JSONDecoder().decode(LaunchHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(reread, history)
        XCTAssertEqual(reread.launchesLine, history.launchesLine)
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
