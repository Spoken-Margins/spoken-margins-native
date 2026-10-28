import XCTest
@testable import SessionKit

/// #2834: the running meeting clock.
final class LiveSessionClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheOriginPlacesZeroWhereTheSourcesOwnClockBegan() throws {
        let live = LiveSession(id: "s", kind: .meeting, startedAt: start, startPositionMs: 12 * 60_000 + 30_000)
        let origin = try XCTUnwrap(LiveSessionClock.origin(of: live))
        XCTAssertEqual(start.timeIntervalSince(origin), 750, accuracy: 0.001)
        // Four minutes later the session counter says 4:00 and the meeting clock says 16:30.
        XCTAssertEqual(start.addingTimeInterval(240).timeIntervalSince(origin), 990, accuracy: 0.001)
    }

    func testTheOriginAgreesWithTheSessionsPredictedPosition() throws {
        var live = LiveSession(id: "s", kind: .meeting, startedAt: start, startPositionMs: 0)
        try LiveSessionEdit.setSourceClock(positionMs: 5 * 60_000, at: start.addingTimeInterval(15 * 60), on: &live)
        let origin = try XCTUnwrap(LiveSessionClock.origin(of: live))
        let later = start.addingTimeInterval(20 * 60)
        XCTAssertEqual(Double(try XCTUnwrap(LiveSessionPositionMap.position(at: later, in: live)).ms) / 1_000, later.timeIntervalSince(origin), accuracy: 0.001)
        XCTAssertGreaterThan(origin, start, "Start was tapped in the lobby, before the meeting's clock began")
    }

    func testAPaperBookAndASessionWithNoStartPositionHaveNoClock() {
        XCTAssertNil(LiveSessionClock.origin(of: LiveSession(id: "p", kind: .paper, startedAt: start, startPositionMs: 5_000)))
        XCTAssertNil(LiveSessionClock.origin(of: LiveSession(id: "a", kind: .audiobook, startedAt: start)))
        XCTAssertNil(LiveSessionClock.title(for: .paper))
        XCTAssertEqual(LiveSessionClock.title(for: .meeting), "Meeting clock")
    }
}
