import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #2883: the Lock Screen card after End keeps the stopped time and the Resume window, and a card an earlier build
/// started still reads as running.
final class LiveSessionEndedActivityAppTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheEndedStateCarriesTheStoppedTimeAndTheWindowAndKeepsTheMarks() throws {
        var live = LiveSession(id: "s", kind: .meeting, startedAt: start)
        live.endedAt = start.addingTimeInterval(45 * 60)
        live.endTappedAt = start.addingTimeInterval(60 * 60)
        let running = LiveSessionActivities.runningState(for: live, markCount: 3, lastMarkAt: start, now: start)
        let plan = try XCTUnwrap(LiveSessionEndedActivity.plan(for: live, now: start.addingTimeInterval(61 * 60)))
        let ended = LiveSessionActivities.endedState(from: running, plan: plan)
        XCTAssertEqual(ended.endedAt, start.addingTimeInterval(45 * 60), "the stopped time, not the tap")
        XCTAssertEqual(ended.resumeUntil, start.addingTimeInterval(60 * 60 + WatchContract.resumeWindow))
        XCTAssertEqual(ended.sessionId, "s")
        XCTAssertEqual(ended.markCount, 3)
        XCTAssertTrue(ended.hasEnded)
        XCTAssertFalse(running.hasEnded)
    }

    func testACardStartedByAnEarlierBuildDecodesAndReadsAsRunning() throws {
        let old = #"{"markCount":2,"lastMarkAt":null}"#
        let state = try JSONDecoder().decode(LiveSessionActivityAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertEqual(state.markCount, 2)
        XCTAssertFalse(state.hasEnded)
        XCTAssertNil(state.sessionId)
        XCTAssertNil(state.resumeUntil)
    }

    func testTheEndedStateRoundTrips() throws {
        let state = LiveSessionActivityAttributes.ContentState(markCount: 1, sessionId: "s", endedAt: start, resumeUntil: start.addingTimeInterval(600))
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(LiveSessionActivityAttributes.ContentState.self, from: data), state)
    }
}
