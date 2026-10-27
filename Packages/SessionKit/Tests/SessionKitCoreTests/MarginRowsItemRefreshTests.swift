import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// A change to one item's Margins swaps in that item's rows and matches a full rebuild (#2505).
final class MarginRowsItemRefreshTests: XCTestCase {
    private var fixture: LibraryFixture?

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private func firstItemId(_ rows: [MarginCollection.PrivateEntry]) throws -> String {
        try XCTUnwrap(rows.first).interjection.itemId
    }

    func testSwappingOneItemsRowsAfterASaveMatchesAFullRebuild() throws {
        let built = try LibraryFixture.build(.small)
        fixture = built
        let store = try built.openStore()
        let before = try MarginRowsReading.all(store: store)
        let itemId = try firstItemId(before.privateRows)

        // A new Margin on that item: an existing one under a new id, as a save would write it.
        var added = try XCTUnwrap(before.privateRows.first { $0.interjection.itemId == itemId }).interjection
        added.id = "new-\(UUID().uuidString)"
        try store.saveInterjection(added)

        let fresh = try MarginRowsReading.item(itemId, store: store)
        let patched = MarginCollection.replacingItem(itemId, in: before.privateRows, with: fresh.privateRows)
        let rebuilt = try MarginRowsReading.all(store: store)
        XCTAssertEqual(patched, rebuilt.privateRows)
        XCTAssertEqual(patched.count, before.privateRows.count + 1)
        XCTAssertEqual(MarginCollection.replacingItem(itemId, in: before.sharedRows, with: fresh.sharedRows), rebuilt.sharedRows)
    }

    func testTrashingAnItemDropsItsRowsAndRestoringBringsThemBack() throws {
        let built = try LibraryFixture.build(.small)
        fixture = built
        let store = try built.openStore()
        let before = try MarginRowsReading.all(store: store)
        let itemId = try firstItemId(before.privateRows)
        let others = before.privateRows.filter { $0.interjection.itemId != itemId }
        XCTAssertLessThan(others.count, before.privateRows.count)

        try store.moveItemToTrash(id: itemId)
        let trashed = try MarginRowsReading.item(itemId, store: store)
        XCTAssertTrue(trashed.privateRows.isEmpty, "a trashed item has no rows")
        let afterTrash = MarginCollection.replacingItem(itemId, in: before.privateRows, with: trashed.privateRows)
        XCTAssertEqual(afterTrash, try MarginRowsReading.all(store: store).privateRows)
        XCTAssertEqual(afterTrash, others)

        try store.restoreItem(id: itemId)
        let restored = try MarginRowsReading.item(itemId, store: store)
        let afterRestore = MarginCollection.replacingItem(itemId, in: afterTrash, with: restored.privateRows)
        XCTAssertEqual(afterRestore, try MarginRowsReading.all(store: store).privateRows)
        XCTAssertEqual(afterRestore.count, before.privateRows.count)
    }

    func testReadingOneItemReadsOneItemsSessionsNotTheWholeLibrary() throws {
        let built = try LibraryFixture.build(.small)
        fixture = built
        let itemId = try firstItemId(MarginRowsReading.all(store: built.openStore()).privateRows)

        let meter = StoreReadMeter()
        let store = try built.openStore(meter: meter)
        _ = try MarginRowsReading.all(store: store)
        let fullRows = meter.totals(for: "loadInterjections(sessionId:)").rows
        XCTAssertGreaterThan(meter.totals(for: "loadSessions()").calls, 0, "the full read does read every session")
        meter.reset()
        _ = try MarginRowsReading.item(itemId, store: store)
        let oneItem = meter.totals(for: "loadInterjections(sessionId:)")
        XCTAssertLessThan(oneItem.rows * 3, fullRows, "one item's sessions, not every session's (\(oneItem.rows) of \(fullRows) rows)")
        XCTAssertEqual(meter.totals(for: "listItems(includeDeleted:)").calls, 0, "no read of every item's text")
        XCTAssertEqual(meter.totals(for: "loadSessions()").calls, 0, "no read of every session")
    }

    func testAMissingItemHasNoRows() throws {
        let built = try LibraryFixture.build(.small)
        fixture = built
        let entries = try MarginRowsReading.item("no-such-item", store: built.openStore())
        XCTAssertTrue(entries.privateRows.isEmpty)
        XCTAssertTrue(entries.sharedRows.isEmpty)
    }
}
