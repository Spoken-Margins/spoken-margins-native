import XCTest
@testable import SessionKit

/// #2832: the kind, name, clock and chapter can be set while the session runs.
final class LiveSessionEditTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(kind: ElsewhereKind = .meeting, startPositionMs: Int? = 0) -> LiveSession {
        LiveSession(id: "live-1", kind: kind, startedAt: start, startPositionMs: startPositionMs)
    }

    func testTheMeetingClockRunsFromWhatTheListenerSaysItIsNow() throws {
        var live = session()
        let now = start.addingTimeInterval(5 * 60)
        try LiveSessionEdit.setSourceClock(positionMs: 12 * 60_000 + 30_000, at: now, on: &live)
        XCTAssertEqual(live.startPositionMs, 7 * 60_000 + 30_000)
        XCTAssertEqual(LiveSessionPositionMap.position(at: now, in: live)?.ms, 12 * 60_000 + 30_000)
        XCTAssertEqual(LiveSessionPositionMap.position(at: now.addingTimeInterval(30), in: live)?.ms, 13 * 60_000)
    }

    func testMarginsAlreadyTakenMoveWithTheClockExceptOnesTheListenerSetByHand() throws {
        var live = session()
        live.margins = [
            live.margin(id: "a", text: "a", markedAt: start.addingTimeInterval(60)),
            live.margin(id: "b", text: "b", markedAt: start.addingTimeInterval(120)),
        ]
        live.margins[1].listenerPositionMs = 99_000
        try LiveSessionEdit.setSourceClock(positionMs: 10 * 60_000, at: start.addingTimeInterval(4 * 60), on: &live)
        XCTAssertEqual(LiveSessionPositionMap.position(of: live.margins[0], in: live)?.ms, 7 * 60_000)
        XCTAssertEqual(LiveSessionPositionMap.position(of: live.margins[1], in: live)?.ms, 99_000)
    }

    func testAClockSmallerThanTheTimeSinceStartIsAllowedForStartTappedInTheLobby() throws {
        var live = session()
        live.margins = [
            live.margin(id: "lobby", text: "", markedAt: start.addingTimeInterval(2 * 60)),
            live.margin(id: "talk", text: "", markedAt: start.addingTimeInterval(14 * 60)),
        ]
        try LiveSessionEdit.setSourceClock(positionMs: 5 * 60_000, at: start.addingTimeInterval(15 * 60), on: &live)
        XCTAssertEqual(live.startPositionMs, -10 * 60_000)
        XCTAssertEqual(LiveSessionPositionMap.position(of: live.margins[0], in: live)?.ms, 0, "before the meeting began")
        XCTAssertEqual(LiveSessionPositionMap.position(of: live.margins[1], in: live)?.ms, 4 * 60_000)
        XCTAssertEqual(LiveSessionPositionMap.position(at: start.addingTimeInterval(15 * 60), in: live)?.ms, 5 * 60_000)
    }

    func testAClockThatPutsTheStartAfterTheEndPositionIsRejected() {
        var live = session()
        live.endPositionMs = 10 * 60_000
        XCTAssertThrowsError(try LiveSessionEdit.setSourceClock(positionMs: 20 * 60_000, at: start.addingTimeInterval(60), on: &live))
        XCTAssertEqual(live.startPositionMs, 0)
    }

    func testAPaperBookHidesTheClockButKeepsItForTheWayBack() {
        var live = session(kind: .meeting, startPositionMs: 90_000)
        LiveSessionEdit.setKind(.audiobook, on: &live)
        XCTAssertEqual(live.startPositionMs, 90_000)
        LiveSessionEdit.setKind(.paper, on: &live)
        XCTAssertNil(LiveSessionPositionMap.position(at: start.addingTimeInterval(60), in: live))
        LiveSessionEdit.setKind(.meeting, on: &live)
        XCTAssertEqual(LiveSessionPositionMap.position(at: start.addingTimeInterval(60), in: live)?.ms, 150_000)
    }

    func testAMeetingFromAKindWithNoClockStaysUnknownNotZero() {
        var live = session(kind: .paper, startPositionMs: nil)
        LiveSessionEdit.setKind(.meeting, on: &live)
        XCTAssertNil(live.startPositionMs, "no clock given: 0:00 would be a guess (#3241)")
        XCTAssertNil(LiveSessionPositionMap.position(at: start.addingTimeInterval(60), in: live))
    }

    func testAMeetingStartedWithBlankClockHasNoPositionUntilTheListenerSetsOne() throws {
        // What the start card sends for a meeting with the clock left blank.
        let read = LiveSessionWhere.interpret(clockText: "  ", whereText: "", kind: .meeting)
        var live = LiveSession(id: "m", kind: .meeting, startedAt: start, startPositionMs: read.positionMs)
        XCTAssertNil(live.startPositionMs)
        XCTAssertNil(LiveSessionPositionMap.position(at: start.addingTimeInterval(300), in: live))
        XCTAssertNil(LiveSessionClock.origin(of: live, now: start.addingTimeInterval(300)))

        try LiveSessionEdit.setSourceClock(positionMs: 12 * 60_000, at: start.addingTimeInterval(300), on: &live)
        XCTAssertEqual(live.startPositionMs, 7 * 60_000)
        XCTAssertEqual(LiveSessionPositionMap.position(at: start.addingTimeInterval(360), in: live)?.ms, 13 * 60_000)
    }

    func testAMeetingWithAPageButNoClockIsPlacedByPageUntilTheClockIsSet() throws {
        let read = LiveSessionWhere.interpret(clockText: "", whereText: "page 12", kind: .meeting)
        var live = LiveSession(id: "m", kind: .meeting, startedAt: start, startPositionMs: read.positionMs, startWhere: read.text)
        live.startPlace = read.place
        XCTAssertTrue(live.usesPlaces)
        try LiveSessionEdit.setSourceClock(positionMs: 60_000, at: start, on: &live)
        XCTAssertFalse(live.usesPlaces, "once the clock is set the meeting is placed by time again")
    }

    func testTheNameAndChapterAreTrimmedAndBlankClearsTheChapter() {
        var live = session()
        LiveSessionEdit.setTitle("  Budget review \n", on: &live)
        XCTAssertEqual(live.title, "Budget review")
        LiveSessionEdit.setStartWhere(" Chapter 4 ", on: &live)
        XCTAssertEqual(live.startWhere, "Chapter 4")
        LiveSessionEdit.setStartWhere("   ", on: &live)
        XCTAssertNil(live.startWhere)
    }

    func testAnEditedSessionStillDecodesWithTheSameFields() throws {
        var live = session()
        try LiveSessionEdit.setSourceClock(positionMs: 60_000, at: start.addingTimeInterval(10), on: &live)
        LiveSessionEdit.setTitle("Edited", on: &live)
        let decoded = try JSONDecoder().decode(LiveSession.self, from: try JSONEncoder().encode(live))
        XCTAssertEqual(decoded, live)
    }
}
