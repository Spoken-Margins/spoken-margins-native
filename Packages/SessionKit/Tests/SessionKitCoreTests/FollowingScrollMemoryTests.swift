import Foundation
import SessionKit
import XCTest

/// #479: which entry Following scrolls back to after the listener opens one and returns.
final class FollowingScrollMemoryTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    private func memory(top: String?, order: [String]? = nil) -> FollowingScrollMemory {
        FollowingScrollMemory(topEntryId: top, order: order ?? self.order)
    }

    /// The saved entry present, removed, and the neighbours of each: entries added above, several
    /// removed at once, the whole tail gone, the whole list replaced, an empty list, nothing saved.
    func testRestoreTargetTable() {
        let table: [(name: String, top: String?, current: [String], target: String?)] = [
            ("saved entry still listed", "c", ["a", "b", "c", "d", "e"], "c"),
            ("was at the top", "a", ["a", "b", "c"], nil),
            ("was at the top and new entries arrived", "a", ["x", "a", "b"], nil),
            ("was at the top and it was removed", "a", ["b", "c"], nil),
            ("new entries arrived above it", "c", ["x", "y", "a", "b", "c", "d", "e"], "c"),
            ("saved entry removed: the next one below", "c", ["a", "b", "d", "e"], "d"),
            ("saved and the next removed: the one after", "c", ["a", "b", "e"], "e"),
            ("everything below removed: nearest above", "c", ["a", "b"], "b"),
            ("saved is the last and removed", "e", ["a", "b", "c", "d"], "d"),
            ("only the first is left", "c", ["a"], "a"),
            ("list replaced by new entries", "c", ["x", "y"], nil),
            ("empty list", "c", [], nil),
            ("nothing saved", nil, ["a", "b"], nil),
        ]
        for row in table {
            XCTAssertEqual(memory(top: row.top).restoreTarget(in: row.current), row.target, row.name)
        }
    }

    func testASavedEntryTheOrderNeverHeldHasNothingToFallBackOn() {
        XCTAssertEqual(memory(top: "z").restoreTarget(in: ["a", "b"]), nil, "removed, and not in the saved order")
        XCTAssertEqual(memory(top: "z").restoreTarget(in: ["z", "a"]), "z", "still listed, so no order is needed")
        XCTAssertEqual(memory(top: "c", order: []).restoreTarget(in: ["a", "c"]), "c")
    }

    func testTopEntryIsTheFirstVisibleOneInListOrder() {
        XCTAssertEqual(FollowingScrollMemory.topEntry(visible: ["d", "b", "c"], order: order), "b")
        XCTAssertEqual(FollowingScrollMemory.topEntry(visible: ["e"], order: order), "e")
        XCTAssertNil(FollowingScrollMemory.topEntry(visible: [], order: order), "nothing on screen keeps the last place")
        XCTAssertNil(FollowingScrollMemory.topEntry(visible: ["z"], order: order), "a row the list no longer has")
        XCTAssertNil(FollowingScrollMemory.topEntry(visible: ["a"], order: []))
    }
}
