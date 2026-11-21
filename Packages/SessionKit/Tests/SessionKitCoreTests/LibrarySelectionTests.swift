import Foundation
import XCTest
@testable import SessionKit

/// #4720: the Library's Select button. What is ticked, what Select All means in the current view, which actions a mixed
/// selection offers, and the count every action reports.
final class LibrarySelectionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ id: String, added: Double = 0, finished: Bool = false, byHand: Bool = false) -> LibraryItemRow {
        var row = LibraryItemRow(id: id, title: "Title \(id)", status: "ready", canDelete: true, isCompleted: finished,
                                 mediaType: "text", addedAt: base.addingTimeInterval(added), storageRecencyRank: .max)
        row.canMarkUnfinished = byHand
        return row
    }

    // MARK: Ticking

    func testTickingAndUntickingAndTheTitle() {
        var selection = LibrarySelection()
        XCTAssertEqual(selection.title, "Select Items")
        selection.toggle("a")
        XCTAssertEqual(selection.title, "1 Selected")
        selection.toggle("b")
        XCTAssertEqual(selection.title, "2 Selected")
        selection.toggle("a")
        XCTAssertEqual(selection.selectedIDs, ["b"])
        XCTAssertEqual(LibrarySelection.rowAccessibilityHint(isSelected: true), "Double-tap to deselect.")
    }

    func testSelectAllTicksWhatTheViewShowsAndThenReadsDeselectAll() {
        var selection = LibrarySelection(selectedIDs: ["elsewhere"])
        let visible = ["a", "b", "c"]
        XCTAssertEqual(selection.selectAllTitle(visible: visible), "Select All")
        selection.toggleAll(visible)
        XCTAssertTrue(selection.isAllSelected(of: visible))
        XCTAssertEqual(selection.selectAllTitle(visible: visible), "Deselect All")
        selection.toggleAll(visible)
        XCTAssertEqual(selection.selectedIDs, ["elsewhere"], "Deselect All clears the view's rows")
        XCTAssertFalse(selection.isAllSelected(of: []), "nothing to select is never all selected")
    }

    func testOnlyItemRowsAreSelectableInTheCollectionsView() {
        let rows = [row("a", added: 1), row("b", added: 2), row("loose", added: 3)]
        let listing = LibraryCollectionListEngine.listing(
            rows: rows, collections: [ItemCollection(id: "x", name: "X", itemIDs: ["a", "b"], createdAt: base)],
            query: LibraryQuery(), mode: .collections, currentItemID: nil)
        XCTAssertEqual(LibrarySelection.selectableIDs(listing), ["loose"], "a collection row is a way in, not a thing to tick")
        let all = LibraryCollectionListEngine.listing(rows: rows, collections: [], query: LibraryQuery(), mode: .allItems, currentItemID: nil)
        XCTAssertEqual(LibrarySelection.selectableIDs(all), ["loose", "b", "a"])
    }

    func testSelectAllUnderAFilterTakesOnlyWhatTheFilterShows() {
        let rows = [row("a", added: 1), row("done", added: 2, finished: true), row("c", added: 3)]
        let unfinished = LibraryCollectionListEngine.listing(rows: rows, collections: [], query: LibraryQuery(listeningState: .unfinished),
                                                             mode: .allItems, currentItemID: nil)
        var selection = LibrarySelection()
        selection.toggleAll(LibrarySelection.selectableIDs(unfinished))
        XCTAssertEqual(selection.selectedIDs, ["a", "c"])
    }

    func testChangingTheViewUnticksWhatItNoLongerShowsAndOrderFollowsTheView() {
        var selection = LibrarySelection(selectedIDs: ["a", "b", "c"])
        selection.keepOnly(["c", "a", "z"])
        XCTAssertEqual(selection.selectedIDs, ["a", "c"])
        XCTAssertEqual(selection.ordered(in: ["z", "c", "q", "a"]), ["c", "a"], "the order the listener sees")
    }

    // MARK: Which actions

    func testActionsForAnEmptyAnUnfinishedAMixedAndAFinishedSelection() {
        XCTAssertEqual(LibraryBulkAction.available(for: [], insideCollection: false), [])
        XCTAssertEqual(LibraryBulkAction.available(for: [row("a")], insideCollection: false),
                       [.addToQueue, .addToCollection, .markFinished, .moveToRecentlyDeleted])
        XCTAssertEqual(LibraryBulkAction.available(for: [row("a"), row("b", finished: true, byHand: true)], insideCollection: false),
                       [.addToQueue, .addToCollection, .markFinished, .markUnfinished, .moveToRecentlyDeleted], "a mixed selection offers both")
        XCTAssertEqual(LibraryBulkAction.available(for: [row("b", finished: true, byHand: true)], insideCollection: true),
                       [.addToQueue, .addToCollection, .markUnfinished, .removeFromCollection, .moveToRecentlyDeleted])
        XCTAssertEqual(LibraryBulkAction.available(for: [row("heard", finished: true)], insideCollection: false),
                       [.addToQueue, .addToCollection, .moveToRecentlyDeleted],
                       "finished by listening can't be marked unfinished, as on the item's own menu")
    }

    func testMarkActionsChangeOnlyTheRowsTheyApplyTo() {
        let rows = [row("a"), row("b", finished: true, byHand: true), row("c", finished: true), row("d")]
        XCTAssertEqual(LibraryBulkAction.markFinished.rowsChanged(rows).map(\.id), ["a", "d"])
        XCTAssertEqual(LibraryBulkAction.markUnfinished.rowsChanged(rows).map(\.id), ["b"])
        XCTAssertEqual(LibraryBulkAction.moveToRecentlyDeleted.rowsChanged(rows).map(\.id), ["a", "b", "c", "d"])
        XCTAssertTrue(LibraryBulkAction.moveToRecentlyDeleted.isDestructive)
        XCTAssertFalse(LibraryBulkAction.allCases.filter { $0 != .moveToRecentlyDeleted }.contains(where: \.isDestructive))
    }

    // MARK: Counts

    func testEveryActionSaysHowManyItTouched() {
        XCTAssertEqual(LibraryBulkAction.markFinished.banner(count: 6), "Marked 6 items as finished.")
        XCTAssertEqual(LibraryBulkAction.markUnfinished.banner(count: 1), "Marked 1 item as unfinished.")
        XCTAssertEqual(LibraryBulkAction.moveToRecentlyDeleted.banner(count: 6), "Moved 6 items to Recently Deleted.")
        XCTAssertEqual(LibraryBulkAction.removeFromCollection.banner(count: 3, collectionName: "FourSight"), "Removed 3 items from “FourSight”.")
        XCTAssertEqual(LibraryBulkAction.queuedBanner(added: 6, selected: 6), "Added 6 items to the queue.")
        XCTAssertEqual(LibraryBulkAction.queuedBanner(added: 4, selected: 6), "Added 4 items to the queue. 2 were already in it.")
        XCTAssertEqual(LibraryBulkAction.queuedBanner(added: 2, selected: 3), "Added 2 items to the queue. 1 was already in it.")
        XCTAssertEqual(LibraryBulkAction.queuedBanner(added: 0, selected: 3), "All 3 items are already in the queue.")
        XCTAssertEqual(LibraryBulkAction.queuedBanner(added: 0, selected: 1), "It's already in the queue.")
        XCTAssertEqual(LibraryBulkAction.collectionBanner(added: 6, selected: 6, name: "FourSight", isNew: true), "Made “FourSight” with 6 items.")
        XCTAssertEqual(LibraryBulkAction.collectionBanner(added: 4, selected: 6, name: "FourSight", isNew: false),
                       "Added 4 items to “FourSight”. 2 were already in it.")
        XCTAssertEqual(LibraryBulkAction.collectionBanner(added: 0, selected: 2, name: "FourSight", isNew: false),
                       "All 2 items are already in “FourSight”.")
        let ask = LibraryBulkAction.deleteConfirmation(count: 6)
        XCTAssertEqual(ask.title, "Move 6 Items to Recently Deleted?")
        XCTAssertEqual(ask.button, "Move 6 Items to Recently Deleted")
        XCTAssertEqual(LibraryBulkAction.deleteConfirmation(count: 1).button, "Move 1 Item to Recently Deleted")
    }

    func testAddToQueueInTheViewsOrderCountsOnlyNewItems() {
        var queue = PlayQueue(itemIds: ["b"])
        let selection = LibrarySelection(selectedIDs: ["a", "b", "c"])
        let added = queue.append(contentsOf: selection.ordered(in: ["c", "b", "a"]))
        XCTAssertEqual(queue.itemIds, ["b", "c", "a"])
        XCTAssertEqual(added, 2)
    }

    // MARK: Collections from a selection

    func testAddingToAnExistingCollectionKeepsItsOrderAndCountsOnlyNewItems() {
        let collection = ItemCollection(id: "x", name: "FourSight", itemIDs: ["b"], createdAt: base)
        let outcome = LibraryCollectionAdding.adding(["a", "b", "c", "a"], to: collection, now: base.addingTimeInterval(5))
        XCTAssertEqual(outcome.collection.itemIDs, ["b", "a", "c"])
        XCTAssertEqual(outcome.added, 2)
        XCTAssertFalse(outcome.isNew)
        XCTAssertEqual(outcome.collection.updatedAt, base.addingTimeInterval(5))
        let nothing = LibraryCollectionAdding.adding(["b"], to: collection, now: base.addingTimeInterval(9))
        XCTAssertEqual(nothing.added, 0)
        XCTAssertEqual(nothing.collection.updatedAt, base, "nothing changed, nothing to save")
    }

    func testANewCollectionNamedInTheSameFlowFollowsTheNameRules() {
        let existing = [ItemCollection(id: "x", name: "FourSight", createdAt: base)]
        let made = LibraryCollectionAdding.creating(name: "  Work   things ", with: ["a", "b"], id: "new", now: base, in: existing)
        XCTAssertEqual(made?.collection.name, "Work things")
        XCTAssertEqual(made?.collection.itemIDs, ["a", "b"])
        XCTAssertEqual(made?.added, 2)
        XCTAssertEqual(made?.isNew, true)
        XCTAssertNil(LibraryCollectionAdding.creating(name: "foursight", with: ["a"], id: "n", now: base, in: existing), "taken, ignoring case")
        XCTAssertNil(LibraryCollectionAdding.creating(name: "   ", with: ["a"], id: "n", now: base, in: existing))
    }

    func testRemovingFromACollectionCountsWhatLeftAndKeepsTheRestInOrder() {
        let collection = ItemCollection(id: "x", name: "X", itemIDs: ["a", "b", "c", "d"], createdAt: base)
        let result = LibraryCollectionAdding.removing(["d", "b", "zz"], from: collection, now: base.addingTimeInterval(1))
        XCTAssertEqual(result.collection.itemIDs, ["a", "c"])
        XCTAssertEqual(result.removed, 2)
    }
}
