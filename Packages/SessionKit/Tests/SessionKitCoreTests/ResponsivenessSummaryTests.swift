import Foundation
import XCTest
@testable import SessionKit

/// #2096: the one-line answer to "did the app freeze, and how slow were taps". Each test builds the event log the
/// app really writes (`main.hang`, `transport.state`, `session.end`) and checks the line, so a field renamed in
/// the recorder without this reader failing shows up here.
final class ResponsivenessSummaryTests: XCTestCase {
    private func log(_ events: [(kind: String, fields: [String: String])]) -> String {
        let rows = events.map { event -> [String: Any] in
            ["time": "2026-10-19T15:24:30.220Z", "kind": event.kind, "elapsedMs": 1, "fields": event.fields]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["events": rows])
        return String(decoding: data, as: UTF8.self)
    }

    private func hang(_ ms: Int, skipped: Int? = nil) -> (kind: String, fields: [String: String]) {
        var fields = ["durationMs": String(ms), "operation": "refreshLibraryRows", "screen": "library"]
        if let skipped { fields["skipped"] = String(skipped) }
        return ("main.hang", fields)
    }

    private func tap(_ ms: Int) -> (kind: String, fields: [String: String]) {
        (TapToStateTracker.eventKind, ["command": "togglePlayPause", "from": "playing", "to": "paused", "tapToStateMs": String(ms)])
    }

    func testAnEmptyLogIsWithinBudget() {
        let summary = ResponsivenessSummary(playbackEventsJSON: "{\"events\":[]}")

        XCTAssertEqual(
            summary.text,
            "hangs=0 skipped=0 longestHangMs=0 hangsOver250Ms=0 taps=0 tapToStateP95Ms=none closes=0 longestCloseMs=none budget=ok")
    }

    func testTextThatIsNotAnEventLogReadsAsEmpty() {
        for text in [nil, "", "not json", "{\"events\":\"no\"}", "[]"] as [String?] {
            XCTAssertEqual(ResponsivenessSummary(playbackEventsJSON: text), ResponsivenessSummary(playbackEventsJSON: "{\"events\":[]}"), "\(text ?? "nil")")
        }
    }

    func testHangsAreCountedAndTheLongestIsNamed() {
        let summary = ResponsivenessSummary(playbackEventsJSON: log([hang(260), hang(640), hang(250)]))

        XCTAssertEqual(summary.hangCount, 3)
        XCTAssertEqual(summary.longestHangMs, 640)
        XCTAssertEqual(summary.hangsOverBudget, 2, "250 ms is the threshold the probe records at; only longer is over budget")
        XCTAssertEqual(summary.brokenBudgets, ["hang"])
        XCTAssertTrue(summary.text.hasSuffix("budget=broken(hang)"))
    }

    func testHangsLeftOutOfTheLogStillBreakTheBudget() {
        let summary = ResponsivenessSummary(playbackEventsJSON: log([hang(250, skipped: 7)]))

        XCTAssertEqual(summary.hangsSkipped, 7)
        XCTAssertEqual(summary.brokenBudgets, ["hang"])
    }

    func testTheTapBudgetIsTheNinetyFifthPercentileNotTheWorstTap() {
        // Twenty taps: 19 fast and one slow. The 95th percentile (nearest rank, the 19th) is still fast.
        let events = Array(repeating: tap(40), count: 19) + [tap(900)]
        let summary = ResponsivenessSummary(playbackEventsJSON: log(events))

        XCTAssertEqual(summary.tapCount, 20)
        XCTAssertEqual(summary.tapToStateP95Ms, 40)
        XCTAssertEqual(summary.brokenBudgets, [])
    }

    func testTwoSlowTapsInTwentyBreakTheTapBudget() {
        let summary = ResponsivenessSummary(playbackEventsJSON: log(Array(repeating: tap(40), count: 18) + [tap(150), tap(900)]))

        XCTAssertEqual(summary.tapToStateP95Ms, 150)
        XCTAssertEqual(summary.brokenBudgets, ["tap"])
    }

    func testPercentileRows() {
        XCTAssertNil(ResponsivenessSummary.percentile95([]))
        XCTAssertEqual(ResponsivenessSummary.percentile95([7]), 7)
        XCTAssertEqual(ResponsivenessSummary.percentile95([100, 100]), 100)
        XCTAssertEqual(ResponsivenessSummary.percentile95(Array(1...100)), 95)
        XCTAssertEqual(ResponsivenessSummary.percentile95(Array((1...100).reversed())), 95, "order doesn't matter")
    }

    func testASlowCloseBreaksTheCloseBudget() {
        let fast = ("session.end", ["reason": "mini_player_close", "tapToEndMs": "120"])
        let slow = ("session.end", ["reason": "mini_player_close", "tapToEndMs": "26500"])
        let other = ("session.end", ["reason": "user_ended"])
        let summary = ResponsivenessSummary(playbackEventsJSON: log([fast, other, slow]))

        XCTAssertEqual(summary.closeCount, 2, "a session end the X didn't cause carries no tapToEndMs and isn't counted")
        XCTAssertEqual(summary.longestCloseMs, 26_500)
        XCTAssertEqual(summary.brokenBudgets, ["close"])
    }

    func testNumbersWrittenAsJSONNumbersAreReadToo() {
        let json = #"{"events":[{"kind":"main.hang","fields":{"durationMs":400}},{"kind":"transport.state","fields":{"tapToStateMs":55}}]}"#
        let summary = ResponsivenessSummary(playbackEventsJSON: json)

        XCTAssertEqual(summary.longestHangMs, 400)
        XCTAssertEqual(summary.tapToStateP95Ms, 55)
    }

    func testUnrelatedEventsAndHangsWithoutADurationAreIgnored() {
        let noise: [(kind: String, fields: [String: String])] = [
            ("playback.state", ["to": "playing"]),
            ("main.hang", ["operation": "none"]),
            (TapToStateTracker.eventKind, ["tapToStateMs": "soon"]),
        ]
        let summary = ResponsivenessSummary(playbackEventsJSON: log(noise))

        XCTAssertEqual(summary.hangCount, 0)
        XCTAssertEqual(summary.tapCount, 0)
        XCTAssertEqual(summary.brokenBudgets, [])
    }

    func testTheExportCarriesTheLineBesideTheEvents() {
        let fixed = DiagnosticsExport.Fixed(
            developerBuild: "0.1 (36) abc1234", developerRecording: nil, playbackEvents: log([hang(900)]),
            exportedAt: Date(timeIntervalSince1970: 1_791_000_000), playbackStatus: "playing",
            sessionPhase: "item_playback", targetType: nil, pendingAIJobs: 0)
        let entries = DiagnosticsExport.entries(live: [:], stored: [:], fixed: fixed)

        XCTAssertEqual(entries["responsiveness"]?.contains("longestHangMs=900"), true)
        XCTAssertEqual(entries["responsiveness"]?.hasSuffix("budget=broken(hang)"), true)
    }
}
