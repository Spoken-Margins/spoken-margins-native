import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2507: a caller that has an item id reads that item's ledger rows, not every row in the ledger.
final class OwnedOfflineAssetsByItemTests: XCTestCase {
    private func asset(_ id: String, item: String?, _ category: OfflineAssetCategory) -> OwnedOfflineAsset {
        OwnedOfflineAsset(id: id, itemId: item, category: category, relativePath: "Assets/\(id)", byteCount: 10, isReproducible: false)
    }

    func testReadsOnlyThatItemsRowsInTheWholeReadsOrder() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("owned-assets-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let meter = StoreReadMeter()
        let store = try SQLiteSessionStore(path: path, readMeter: meter)
        for row in [
            asset("a-chunk-1", item: "item-a", .preparedChunk), asset("b-book", item: "item-b", .audiobook),
            asset("a-book", item: "item-a", .audiobook), asset("orphan", item: nil, .guidedTour),
            asset("c-podcast", item: "item-c", .podcast), asset("a-chunk-2", item: "item-a", .preparedChunk),
        ] { try store.saveOwnedOfflineAsset(row) }

        meter.reset()
        let mine = try store.loadOwnedOfflineAssets(itemId: "item-a")
        let byItem = meter.totals(for: "loadOwnedOfflineAssets(itemId:)")

        XCTAssertEqual(mine.map(\.id), try store.loadOwnedOfflineAssets().filter { $0.itemId == "item-a" }.map(\.id))
        XCTAssertEqual(Set(mine.map(\.id)), ["a-chunk-1", "a-book", "a-chunk-2"])
        XCTAssertEqual(byItem.rows, 3, "the other items' rows are not decoded")
        XCTAssertEqual(try store.loadOwnedOfflineAssets(itemId: "item-none"), [])
    }

    func testARowSavedAgainForAnotherItemMovesWithIt() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("owned-assets-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        try store.saveOwnedOfflineAsset(asset("moved", item: "item-a", .audiobook))
        try store.saveOwnedOfflineAsset(asset("moved", item: "item-b", .audiobook))
        XCTAssertEqual(try store.loadOwnedOfflineAssets(itemId: "item-a"), [])
        XCTAssertEqual(try store.loadOwnedOfflineAssets(itemId: "item-b").map(\.id), ["moved"])
    }
}
