import SessionKit
import XCTest

/// The Timeline rail's order: precise place, then provenance rank, then a conversation parent first, then id (#448, #473).
final class TimelineRailSortKeyTests: XCTestCase {
    func testOrdersBySourcePositionThenRank() {
        let keys = [
            TimelineRailSortKey(position: 60, rank: 0, id: "chapter-later"),
            TimelineRailSortKey(position: 25, rank: 2, id: "assistant"),
            TimelineRailSortKey(position: 25, rank: 1, id: "margin"),
            TimelineRailSortKey(position: 25, rank: 0, id: "chapter"),
        ]

        XCTAssertEqual(keys.sorted().map(\.id), ["chapter", "margin", "assistant", "chapter-later"])
    }

    func testPrecisePlaceBreaksTiesInsideOneRoundedPercent() {
        let keys = [
            TimelineRailSortKey(position: 25, rank: 0, id: "b", precisePosition: 25.4),
            TimelineRailSortKey(position: 25, rank: 0, id: "a", precisePosition: 25.1),
        ]

        XCTAssertEqual(keys.sorted().map(\.id), ["a", "b"])
    }

    func testConversationFollowsItsParentAtOnePlace() {
        // A reply takes its parent's precise place, so thread order, not the id, decides between them.
        let keys = [
            TimelineRailSortKey(position: 30, rank: 1, threadOrder: 2, id: "a-reply", precisePosition: 30.0),
            TimelineRailSortKey(position: 30, rank: 1, threadOrder: 1, id: "z-parent", precisePosition: 30.0),
            TimelineRailSortKey(position: 30, rank: 1, threadOrder: 0, id: "elsewhere", precisePosition: 30.0),
        ]

        XCTAssertEqual(keys.sorted().map(\.id), ["elsewhere", "z-parent", "a-reply"])
    }

    func testNonFinitePreciseFallsBackToRoundedPosition() {
        let key = TimelineRailSortKey(position: 10, rank: 0, id: "x", precisePosition: .nan)
        XCTAssertNil(key.precisePosition)
    }
}
