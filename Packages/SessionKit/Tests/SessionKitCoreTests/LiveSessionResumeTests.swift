import Foundation
import XCTest
@testable import SessionKit

/// #2883: Resume from the phone, and the card that offers it after End.
final class LiveSessionResumeTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func minutes(_ value: Double) -> Date { start.addingTimeInterval(value * 60) }

    /// Started at minute 0, stopped at minute 45, told us at minute 60.
    private func endedLate(id: String = "s") throws -> LiveSession {
        var live = LiveSession(id: id, kind: .meeting, title: "Standup", startedAt: start)
        live.margins = [
            live.margin(id: "during", text: "a", markedAt: minutes(40)),
            live.margin(id: "gap", text: "b", markedAt: minutes(50)),
        ]
        try LiveSessionEnd.end(&live, when: .minutesAgo(15), tappedAt: minutes(60), endPositionMs: nil, endWhere: nil, calendar: calendar)
        return live
    }

    // MARK: The card

    func testTheCardShowsTheStoppedTimeAndTheWindowRunsFromTheTap() throws {
        let live = try endedLate()
        let plan = try XCTUnwrap(LiveSessionEndedActivity.plan(for: live, now: minutes(60)))
        XCTAssertEqual(plan.stoppedAt, minutes(45), "the card says when it stopped, not when End was tapped")
        XCTAssertEqual(plan.resumeUntil, minutes(60).addingTimeInterval(WatchContract.resumeWindow))
    }

    func testThereIsNoCardForASessionEndedAtOnceOnlyAfterItsWindow() throws {
        var plain = LiveSession(id: "p", startedAt: start)
        plain.endedAt = minutes(30)
        XCTAssertEqual(LiveSessionEndedActivity.plan(for: plain, now: minutes(30))?.stoppedAt, minutes(30))
        XCTAssertNil(LiveSessionEndedActivity.plan(for: plain, now: minutes(30).addingTimeInterval(WatchContract.resumeWindow + 1)))
    }

    func testThereIsNoCardForASessionThatRunsIsSavedIsQuickOrIsAPlaceholder() throws {
        XCTAssertNil(LiveSessionEndedActivity.plan(for: LiveSession(id: "r", startedAt: start), now: minutes(1)))
        var saved = try endedLate()
        saved.savedItemId = "item"
        XCTAssertNil(LiveSessionEndedActivity.plan(for: saved, now: minutes(61)))
        var quick = try endedLate()
        quick.isQuick = true
        XCTAssertNil(LiveSessionEndedActivity.plan(for: quick, now: minutes(61)))
        var placeholder = try endedLate()
        placeholder.endReason = LiveSessionWatchSessions.EndReason.placeholder.rawValue
        XCTAssertNil(LiveSessionEndedActivity.plan(for: placeholder, now: minutes(61)))
    }

    // MARK: The rules

    func testResumableUntilIsTheWatchWindowAndMatchesResume() throws {
        let live = try endedLate()
        let until = try XCTUnwrap(LiveSessionWatchSessions.resumableUntil(id: "s", sessions: ["s": live]))
        XCTAssertNotNil(LiveSessionWatchSessions.resume(id: "s", at: until, sessions: ["s": live]))
        XCTAssertNil(LiveSessionWatchSessions.resume(id: "s", at: until.addingTimeInterval(1), sessions: ["s": live]))
    }

    func testAnotherNamedSessionStartedSinceMeansNoResume() throws {
        let live = try endedLate()
        let later = LiveSession(id: "later", startedAt: minutes(61))
        XCTAssertNil(LiveSessionWatchSessions.resumableUntil(id: "s", sessions: ["s": live, "later": later]))
        XCTAssertNil(LiveSessionWatchSessions.resume(id: "s", at: minutes(62), sessions: ["s": live, "later": later]))
        // A quick session is not "what the listener is doing".
        var quick = LiveSession(id: "quick", startedAt: minutes(61))
        quick.isQuick = true
        XCTAssertNotNil(LiveSessionWatchSessions.resumableUntil(id: "s", sessions: ["s": live, "quick": quick]))
    }

    func testResumeDropsTheStoppedTimeAndTheGapMarginsLoseTheNote() throws {
        let live = try endedLate()
        XCTAssertEqual(live.margins[1].filingNote, LiveSessionFiling.afterEndNote)
        let resumed = try XCTUnwrap(LiveSessionWatchSessions.resume(id: "s", at: minutes(62), sessions: ["s": live]))
        XCTAssertNil(resumed.endedAt)
        XCTAssertNil(resumed.endTappedAt)
        XCTAssertEqual(resumed.resumedAt, minutes(62))
        XCTAssertNil(resumed.margins[1].filingNote)
    }

    // MARK: The worker

    private func worker() throws -> (LiveSessionFileWorker, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LiveSessionFileWorker(root: root), root)
    }

    func testThePhoneResumesAStoredSessionAndTheStoreAndSummaryAgree() async throws {
        let (files, root) = try worker()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await files.save(try endedLate(), generation: 1)
        let before = await files.summaries(now: minutes(62))
        XCTAssertEqual(before.first?.resumableUntil, minutes(60).addingTimeInterval(WatchContract.resumeWindow))
        XCTAssertEqual(before.first?.isRunning, false)

        let resumed = await files.resume(id: "s", at: minutes(62))
        XCTAssertNotNil(resumed)
        let stored = await files.session(id: "s")
        XCTAssertNil(stored?.endedAt)
        XCTAssertEqual(stored?.resumedAt, minutes(62))
        let after = await files.summaries(now: minutes(62))
        XCTAssertEqual(after.first?.isRunning, true)
        XCTAssertNil(after.first?.resumableUntil)
        // The Watch is told it runs.
        let board = await files.watchBoard(now: minutes(62))
        XCTAssertEqual(board.running?.id, "s")
    }

    func testAResumeAfterTheWindowOrForAnUnknownSessionIsRefusedAndAskingTwiceIsHarmless() async throws {
        let (files, root) = try worker()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await files.save(try endedLate(), generation: 1)
        let late = minutes(60).addingTimeInterval(WatchContract.resumeWindow + 60)
        let refused = await files.applyResumes([.init(sessionId: "s", at: late), .init(sessionId: "ghost", at: minutes(61))])
        XCTAssertEqual(refused.resumed, [])
        XCTAssertEqual(Set(refused.refused), ["s", "ghost"])
        let stillEnded = await files.session(id: "s")
        XCTAssertNotNil(stillEnded?.endedAt)

        // Two taps inside the window: the session runs, the second changes nothing and is not "refused".
        let twice = await files.applyResumes([.init(sessionId: "s", at: minutes(62)), .init(sessionId: "s", at: minutes(63))])
        XCTAssertEqual(twice.resumed.map(\.id), ["s"])
        XCTAssertEqual(twice.refused, [])
        let again = await files.applyResumes([.init(sessionId: "s", at: minutes(64))])
        XCTAssertEqual(again, LiveSessionFileWorker.ResumeResult())
    }

    // MARK: The Lock Screen's request

    private final class MemoryStore: LiveSessionMarkStore {
        var times: [String: Double] = [:]
        func markKeys(prefix: String) -> [String] { times.keys.filter { $0.hasPrefix(prefix) } }
        func markTime(forKey key: String) -> Double? { times[key] }
        func setMarkTime(_ time: Double, forKey key: String) { times[key] = time }
        func removeMark(forKey key: String) { times[key] = nil }
    }

    func testTheInboxKeepsTheFirstTapPerSessionAndDrainsOnce() {
        let store = MemoryStore()
        let inbox = LiveSessionResumeInbox(store: store)
        inbox.request(sessionId: "a", at: minutes(61))
        inbox.request(sessionId: "a", at: minutes(63))
        inbox.request(sessionId: "b", at: minutes(60))
        store.times["LiveSessionMark.v2.x"] = 5 // a Mark is not a Resume
        let drained = inbox.drain()
        XCTAssertEqual(drained.map(\.sessionId), ["b", "a"])
        XCTAssertEqual(drained.last?.at, minutes(61))
        XCTAssertTrue(inbox.drain().isEmpty)
        XCTAssertEqual(store.times.keys.sorted(), ["LiveSessionMark.v2.x"])
    }
}
