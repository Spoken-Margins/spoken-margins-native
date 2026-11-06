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

    // MARK: Recording on the card (#3499)

    func testACardFromAnEarlierBuildDoesNotReadAsRecording() throws {
        let old = #"{"markCount":2,"lastMarkAt":null}"#
        let state = try JSONDecoder().decode(LiveSessionActivityAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertNil(state.isRecordingMargin)
        XCTAssertFalse(state.isRecordingNow)
    }

    func testTheRecordingFlagRoundTripsAndDrivesTheCard() throws {
        let state = LiveSessionActivityAttributes.ContentState(markCount: 1, sessionId: "s", isRecordingMargin: true)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(LiveSessionActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(back, state)
        XCTAssertTrue(back.isRecordingNow)
    }

    func testAnEndedCardNeverReadsAsRecording() throws {
        var live = LiveSession(id: "s", kind: .meeting, startedAt: start)
        live.endedAt = start.addingTimeInterval(45 * 60)
        live.endTappedAt = start.addingTimeInterval(60 * 60)
        var running = LiveSessionActivities.runningState(for: live, markCount: 1, lastMarkAt: nil, now: start)
        running.isRecordingMargin = true
        let plan = try XCTUnwrap(LiveSessionEndedActivity.plan(for: live, now: start.addingTimeInterval(61 * 60)))
        let ended = LiveSessionActivities.endedState(from: running, plan: plan)
        XCTAssertFalse(ended.isRecordingNow)
        XCTAssertNil(ended.isRecordingMargin)
    }

    /// Finish on the card matters most with the phone locked and no screen open, so the recording's owner hears it,
    /// not a screen (#3499, #3489). No controller exists in this test.
    @MainActor
    func testFinishOnTheCardStopsARecordingWithNoScreenOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = LiveSessionSpokenCapture(files: LiveSessionFileWorker(root: root))
        capture.start(sessionId: "s")
        XCTAssertTrue(capture.isRecording(for: "s"))

        NotificationCenter.default.post(name: LiveSessionFinishMargin.requested, object: nil)

        for _ in 0..<50 where capture.isRecording(for: "s") {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(capture.isRecording(for: "s"))
    }
}
