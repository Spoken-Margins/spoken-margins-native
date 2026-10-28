import Foundation
import XCTest
@testable import SessionKit

/// #2709: ending a session when it stopped, not when the listener tapped End.
final class LiveSessionEndTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let start = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")!

    private func tap(minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func session(start startMs: Int? = 0) -> LiveSession {
        LiveSession(id: "s", kind: .audiobook, startedAt: start, startPositionMs: startMs)
    }

    func testNowChangesNothing() throws {
        var live = session()
        try LiveSessionEnd.end(&live, when: .now, tappedAt: tap(minutes: 60), endPositionMs: 3_600_000, endWhere: "Chapter 4", calendar: calendar)
        XCTAssertEqual(live.endedAt, tap(minutes: 60))
        XCTAssertNil(live.endTappedAt)
        XCTAssertEqual(LiveSessionPositionMap.rate(for: live), 1, accuracy: 1e-9)
        XCTAssertEqual(live.endWhere, "Chapter 4")
    }

    func testAnEarlierStopChangesTheRateAndKeepsTheTapTime() throws {
        // Told us at minute 60 that it stopped at minute 45, after 45 minutes of the book.
        var now = session(), earlier = session()
        try LiveSessionEnd.end(&now, when: .now, tappedAt: tap(minutes: 60), endPositionMs: 2_700_000, endWhere: nil, calendar: calendar)
        try LiveSessionEnd.end(&earlier, when: .minutesAgo(15), tappedAt: tap(minutes: 60), endPositionMs: 2_700_000, endWhere: nil, calendar: calendar)
        XCTAssertEqual(earlier.endedAt, tap(minutes: 45))
        XCTAssertEqual(earlier.endTappedAt, tap(minutes: 60))
        XCTAssertEqual(LiveSessionPositionMap.rate(for: now), 0.75, accuracy: 1e-9)
        XCTAssertEqual(LiveSessionPositionMap.rate(for: earlier), 1, accuracy: 1e-9)
        let at30 = LiveSessionPositionMap.position(at: tap(minutes: 30), in: earlier)?.ms
        XCTAssertEqual(at30, 1_800_000)
        XCTAssertNotEqual(at30, LiveSessionPositionMap.position(at: tap(minutes: 30), in: now)?.ms)
    }

    func testMarginsAfterTheStopAreKeptAndNoted() throws {
        var live = session()
        live.margins = [
            live.margin(id: "during", text: "a", markedAt: tap(minutes: 40)),
            live.margin(id: "after", text: "b", markedAt: tap(minutes: 50)),
            { var m = live.margin(id: "noted", text: "c", markedAt: tap(minutes: 55)); m.filingNote = "moved from a quick session"; return m }()
        ]
        try LiveSessionEnd.end(&live, when: .minutesAgo(15), tappedAt: tap(minutes: 60), endPositionMs: nil, endWhere: nil, calendar: calendar)
        XCTAssertEqual(live.margins.map(\.id), ["during", "after", "noted"])
        XCTAssertNil(live.margins[0].filingNote)
        XCTAssertEqual(live.margins[1].filingNote, LiveSessionFiling.afterEndNote)
        XCTAssertEqual(live.margins[2].filingNote, "moved from a quick session")
    }

    func testStoppedTimesBeforeTheStartOrAfterTheTapAreRejectedAndChangeNothing() {
        var live = session()
        XCTAssertThrowsError(try LiveSessionEnd.end(&live, when: .minutesAgo(60), tappedAt: tap(minutes: 30), endPositionMs: nil, endWhere: nil, calendar: calendar)) {
            XCTAssertEqual($0 as? LiveSessionEnd.Failure, .stoppedBeforeStart)
        }
        XCTAssertNoThrow(try LiveSessionEnd.validate(stoppedAt: start, startedAt: start, tappedAt: tap(minutes: 30)))
        XCTAssertThrowsError(try LiveSessionEnd.validate(stoppedAt: tap(minutes: 31), startedAt: start, tappedAt: tap(minutes: 30))) {
            XCTAssertEqual($0 as? LiveSessionEnd.Failure, .stoppedAfterTap)
        }
        XCTAssertNil(live.endedAt)
        XCTAssertNil(live.endTappedAt)
        // An end position before the start position is still refused, as before.
        var booked = session(start: 600_000)
        XCTAssertThrowsError(try LiveSessionEnd.end(&booked, when: .now, tappedAt: tap(minutes: 30), endPositionMs: 300_000, endWhere: nil, calendar: calendar)) {
            XCTAssertEqual($0 as? LiveSessionPositionMap.Failure, .endBeforeStart)
        }
        XCTAssertNil(booked.endedAt)
        XCTAssertEqual(LiveSessionEnd.Failure.stoppedBeforeStart.errorDescription, "That time is before the session started. Pick a time after it began.")
    }

    func testQuickChoicesStayInsideTheSession() {
        let labels = { (minutes: Double) in LiveSessionEnd.quickChoices(startedAt: self.start, tappedAt: self.tap(minutes: minutes)).map(\.label) }
        XCTAssertEqual(labels(90), ["Now", "5 minutes ago", "15 minutes ago", "30 minutes ago", "1 hour ago"])
        XCTAssertEqual(labels(20), ["Now", "5 minutes ago", "15 minutes ago"])
        XCTAssertEqual(labels(3), ["Now"])
    }

    func testATimeOfDayIsTheLatestSuchTimeAtOrBeforeTheTap() throws {
        let tapped = ISO8601DateFormatter().date(from: "2026-03-05T00:10:00Z")!
        let lastNight = try XCTUnwrap(LiveSessionEnd.When.clockTime(hour: 23, minute: 50).date(tappedAt: tapped, calendar: calendar))
        XCTAssertEqual(lastNight, ISO8601DateFormatter().date(from: "2026-03-04T23:50:00Z"))
        let thisMinute = try XCTUnwrap(LiveSessionEnd.When.clockTime(hour: 0, minute: 10).date(tappedAt: tapped, calendar: calendar))
        XCTAssertEqual(thisMinute, ISO8601DateFormatter().date(from: "2026-03-05T00:10:00Z"))
        let yesterday = try XCTUnwrap(LiveSessionEnd.When.clockTime(hour: 0, minute: 30).date(tappedAt: tapped, calendar: calendar))
        XCTAssertEqual(yesterday, ISO8601DateFormatter().date(from: "2026-03-04T00:30:00Z"))
    }

    func testAnOlderSessionWithoutATapTimeStillDecodesAndANewOneRoundTrips() throws {
        var live = session()
        try LiveSessionEnd.end(&live, when: .minutesAgo(5), tappedAt: tap(minutes: 20), endPositionMs: nil, endWhere: nil, calendar: calendar)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(live)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(LiveSession.self, from: data), live)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["endTappedAt"] = nil
        let old = try decoder.decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.endTappedAt)
        XCTAssertEqual(old.endedAt, live.endedAt)
    }

    func testTheWatchResumeWindowRunsFromTheTapAndResumeDropsTheStoppedTime() throws {
        var live = session()
        try LiveSessionEnd.end(&live, when: .minutesAgo(30), tappedAt: tap(minutes: 60), endPositionMs: nil, endWhere: nil, calendar: calendar)
        // 5 minutes after the tap is 35 minutes after the stopped time: inside the window only if it runs from the tap.
        let resumed = LiveSessionWatchSessions.resume(id: "s", at: tap(minutes: 65), sessions: ["s": live])
        XCTAssertNotNil(resumed)
        XCTAssertNil(resumed?.endedAt)
        XCTAssertNil(resumed?.endTappedAt)
        // Past the window from the tap, it is refused.
        let late = tap(minutes: 60).addingTimeInterval(WatchContract.resumeWindow + 60)
        XCTAssertNil(LiveSessionWatchSessions.resume(id: "s", at: late, sessions: ["s": live]))
    }
}
