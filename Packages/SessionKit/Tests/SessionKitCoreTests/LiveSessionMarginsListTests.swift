import XCTest
@testable import SessionKit

/// #3491: the live screen lists Margins in the playback list's order.
final class LiveSessionMarginsListTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func ids(_ live: LiveSession) -> [String] { LiveSessionMarginsList.rows(for: live).map(\.id) }

    func testAMarginsPositionBeatsWhenItWasTaken() {
        var live = LiveSession(id: "s", kind: .meeting, startedAt: start, startPositionMs: 0)
        var early = live.margin(id: "early", text: "e", markedAt: start.addingTimeInterval(10))
        early.listenerPositionMs = 500_000
        let late = live.margin(id: "late", text: "l", markedAt: start.addingTimeInterval(200))
        live.margins = [early, late]
        XCTAssertEqual(ids(live), ["late", "early"])
    }

    func testWithNoClockMarginsFallBackToWhenTheyWereTaken() {
        var live = LiveSession(id: "s", kind: .audiobook, startedAt: start)
        live.margins = [
            live.margin(id: "b", text: "", markedAt: start.addingTimeInterval(20)),
            live.margin(id: "a", text: "", markedAt: start.addingTimeInterval(10)),
        ]
        let rows = LiveSessionMarginsList.rows(for: live)
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
        XCTAssertTrue(rows.allSatisfy { $0.position == nil })
        XCTAssertEqual(rows[0].createdAt, start.addingTimeInterval(10))
    }

    func testAPaperBooksMarginsGoByPageNotByTime() throws {
        var live = LiveSession(id: "s", kind: .paper, startedAt: start)
        live.startPlace = LiveSessionPlace(unit: .page, value: 10)
        var first = live.margin(id: "taken-first", text: "", markedAt: start.addingTimeInterval(10))
        first.place = LiveSessionPlace(unit: .page, value: 90)
        var second = live.margin(id: "taken-second", text: "", markedAt: start.addingTimeInterval(20))
        second.place = LiveSessionPlace(unit: .page, value: 30)
        live.margins = [first, second]
        let rows = LiveSessionMarginsList.rows(for: live)
        XCTAssertEqual(rows.map(\.id), ["taken-second", "taken-first"])
        XCTAssertEqual(rows.first?.position, .charOffset(30))
    }

    func testTiesGoOlderFirst() {
        var live = LiveSession(id: "s", kind: .meeting, startedAt: start, startPositionMs: 0)
        var newer = live.margin(id: "a-newer", text: "", markedAt: start.addingTimeInterval(50))
        var older = live.margin(id: "z-older", text: "", markedAt: start.addingTimeInterval(40))
        newer.listenerPositionMs = 60_000
        older.listenerPositionMs = 60_000
        live.margins = [newer, older]
        XCTAssertEqual(ids(live), ["z-older", "a-newer"])
    }

    func testPositionLabels() {
        var meeting = LiveSession(id: "s", kind: .meeting, startedAt: start, startPositionMs: 0)
        var set = meeting.margin(id: "set", text: "", markedAt: start.addingTimeInterval(65))
        set.listenerPositionMs = 150_000
        let plain = meeting.margin(id: "plain", text: "", markedAt: start.addingTimeInterval(65))
        meeting.margins = [set, plain]
        XCTAssertEqual(LiveSessionMarginsList.positionLabel(for: set, in: meeting), "you set 2:30")
        XCTAssertEqual(LiveSessionMarginsList.positionLabel(for: plain, in: meeting), LiveSessionPositionMap.position(of: plain, in: meeting)?.label)

        let audiobook = LiveSession(id: "a", kind: .audiobook, startedAt: start)
        let noClock = audiobook.margin(id: "n", text: "", markedAt: start.addingTimeInterval(125))
        XCTAssertEqual(LiveSessionMarginsList.positionLabel(for: noClock, in: audiobook), "2:05 in")

        var paper = LiveSession(id: "p", kind: .paper, startedAt: start)
        var onPage = paper.margin(id: "pg", text: "", markedAt: start.addingTimeInterval(5))
        onPage.place = LiveSessionPlace(unit: .page, value: 118)
        paper.margins = [onPage]
        XCTAssertEqual(LiveSessionMarginsList.positionLabel(for: onPage, in: paper), "page 118")
        XCTAssertFalse(LiveSessionMarginsList.positionLabel(for: onPage, in: paper).contains(":"))
    }
}
