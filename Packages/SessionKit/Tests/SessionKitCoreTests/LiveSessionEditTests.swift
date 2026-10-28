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

    func testAClockEarlierThanTheTimeSinceStartIsRejectedAndChangesNothing() {
        var live = session(startPositionMs: 30_000)
        XCTAssertThrowsError(try LiveSessionEdit.setSourceClock(positionMs: 60_000, at: start.addingTimeInterval(5 * 60), on: &live)) { error in
            XCTAssertEqual(error as? LiveSessionEdit.Failure, .clockBeforeStart(sessionTime: "5:00"))
        }
        XCTAssertEqual(live.startPositionMs, 30_000)
    }

    func testAClockThatPutsTheStartAfterTheEndPositionIsRejected() {
        var live = session()
        live.endPositionMs = 10 * 60_000
        XCTAssertThrowsError(try LiveSessionEdit.setSourceClock(positionMs: 20 * 60_000, at: start.addingTimeInterval(60), on: &live))
        XCTAssertEqual(live.startPositionMs, 0)
    }

    func testChangingTheKindKeepsTheClockExceptForAPaperBook() {
        var live = session(kind: .meeting, startPositionMs: 90_000)
        LiveSessionEdit.setKind(.audiobook, on: &live)
        XCTAssertEqual(live.kind, .audiobook)
        XCTAssertEqual(live.startPositionMs, 90_000)
        LiveSessionEdit.setKind(.paper, on: &live)
        XCTAssertNil(live.startPositionMs)
        XCTAssertNil(live.endPositionMs)
        LiveSessionEdit.setKind(.meeting, on: &live)
        XCTAssertEqual(live.startPositionMs, 0)
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
