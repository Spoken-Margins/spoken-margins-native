import XCTest
@testable import SessionKit

/// #585: completing the top Library row must remove that row, not another one.
final class LibraryListRowsTests: XCTestCase {
    private struct Row: Identifiable, Equatable {
        let id: String
    }

    private func identities(_ entries: [LibraryListEntry<Row>]) -> [AnyHashable] {
        entries.map { AnyHashable($0.id) }
    }

    /// The owner's case: the Continue row is completed with completed items hidden, and an
    /// item further down (the podcast at 31%) becomes the Continue row.
    func testCompletingTheContinueRowRemovesOnlyThatRow() {
        let before = LibraryListRows.entries(
            visible: [Row(id: "essay"), Row(id: "crosswalk"), Row(id: "podcast"), Row(id: "notes")],
            currentId: "essay"
        )
        let after = LibraryListRows.entries(
            visible: [Row(id: "crosswalk"), Row(id: "podcast"), Row(id: "notes")],
            currentId: "podcast"
        )

        let removed = Set(identities(before)).subtracting(identities(after))
        let inserted = Set(identities(after)).subtracting(identities(before))
        XCTAssertEqual(removed, [AnyHashable("essay")], "the completed row is the one the list removes")
        XCTAssertEqual(inserted, [], "no row is drawn as a new row; the new Continue row moves up")

        XCTAssertEqual(after.map(\.row), [Row(id: "podcast"), Row(id: "crosswalk"), Row(id: "notes")])
        XCTAssertEqual(after.map(\.isCurrent), [true, false, false])
        for entry in before + after {
            XCTAssertEqual(AnyHashable(entry.id), AnyHashable(entry.row.id))
        }
    }

    func testContinueRowLeavingWithNoReplacementRemovesOnlyThatRow() {
        let before = LibraryListRows.entries(visible: [Row(id: "a"), Row(id: "b")], currentId: "a")
        let after = LibraryListRows.entries(visible: [Row(id: "b")], currentId: nil)

        XCTAssertEqual(Set(identities(before)).subtracting(identities(after)), [AnyHashable("a")])
        XCTAssertEqual(after.map(\.isCurrent), [false])
    }

    func testNoContinueRowKeepsTheVisibleOrder() {
        let entries = LibraryListRows.entries(visible: [Row(id: "a"), Row(id: "b")], currentId: nil)
        XCTAssertEqual(entries.map(\.row), [Row(id: "a"), Row(id: "b")])
        XCTAssertEqual(entries.map(\.isCurrent), [false, false])
    }

    /// A Continue item hidden by the filters isn't drawn (the old `visibleContinueItem` rule).
    func testHiddenContinueItemIsNotDrawn() {
        let entries = LibraryListRows.entries(visible: [Row(id: "a"), Row(id: "b")], currentId: "hidden")
        XCTAssertEqual(entries.map(\.row), [Row(id: "a"), Row(id: "b")])
        XCTAssertEqual(entries.map(\.isCurrent), [false, false])
    }

    /// Moved from the app's `testCompactItemsRemoveOnlyTheContinueItemIdentity`: rows are
    /// matched by id, never by title, and the Continue item is drawn once.
    func testContinueItemIsMatchedByIdAndDrawnOnce() {
        let entries = LibraryListRows.entries(
            visible: [Row(id: "hero"), Row(id: "same-title"), Row(id: "hero"), Row(id: "other")],
            currentId: "hero"
        )
        XCTAssertEqual(entries.map(\.row), [Row(id: "hero"), Row(id: "same-title"), Row(id: "other")])
    }

    func testContinueItemMovesToTheTop() {
        let entries = LibraryListRows.entries(
            visible: [Row(id: "a"), Row(id: "b"), Row(id: "c")],
            currentId: "c"
        )
        XCTAssertEqual(entries.map(\.row), [Row(id: "c"), Row(id: "a"), Row(id: "b")])
        XCTAssertEqual(entries.map(\.isCurrent), [true, false, false])
    }
}
