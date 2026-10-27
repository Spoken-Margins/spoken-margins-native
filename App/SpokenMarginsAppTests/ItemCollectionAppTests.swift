import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// App-hosted checks for Collections (#490): the Export Sessions preselection and what deleting a collection leaves.
@MainActor
final class ItemCollectionAppTests: XCTestCase {
    private struct Imported {
        let itemID: String
        let sessionID: String
    }

    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        // Sessions don't depend on persisted first-run voice consent.
        model.declineCurrentTerms()
        return model
    }

    /// Imports a text item and, when `margin` is given, writes one Margin on it.
    private func importItem(_ model: Gate1AppModel, title: String, margin: String?) throws -> Imported {
        model.importTitle = title
        model.importText = "Source text for \(title)."
        model.importTextItem()
        model.pause()
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        if let margin {
            model.beginWrittenMargin()
            model.saveWrittenMargin(text: margin)
        }
        return Imported(itemID: model.selectedItem.id, sessionID: sessionID)
    }

    private func save(_ collection: ItemCollection, in model: Gate1AppModel) throws {
        try XCTUnwrap(model.store).saveItemCollection(collection)
    }

    func testExportSessionsPreselectsOnlyTheScopedCollectionsSessions() async throws {
        let model = makeModel()
        let first = try importItem(model, title: "Course Reading One", margin: "Margin on the first reading.")
        let second = try importItem(model, title: "Course Reading Two", margin: "Margin on the second reading.")
        let outside = try importItem(model, title: "Unrelated Article", margin: "Margin outside the course.")
        let quiet = try importItem(model, title: "Course Reading Without Margins", margin: nil)
        let collection = ItemCollection(id: "collection-hist-210", name: "HIST 210",
                                        itemIDs: [first.itemID, second.itemID, quiet.itemID], createdAt: Date())
        try save(collection, in: model)

        await model.openBatchExport(scopedTo: ItemCollectionScope(collection)).value

        XCTAssertEqual(model.screen, .batchExport)
        XCTAssertEqual(model.batchExportFilter, .withInterjections)
        XCTAssertEqual(model.selectedBatchExportSessionIds, [first.sessionID, second.sessionID],
                       "only the collection's sessions the default With Margins list shows start selected")
        XCTAssertFalse(model.selectedBatchExportSessionIds.contains(outside.sessionID))
        XCTAssertFalse(model.selectedBatchExportSessionIds.contains(quiet.sessionID))
        XCTAssertEqual(Set(model.visibleBatchExportRows.map(\.id)), [first.sessionID, second.sessionID, outside.sessionID],
                       "the list still shows every session with Margins; only the selection is scoped")
    }

    func testExportSessionsWithNoCollectionStartsWithNothingSelected() async throws {
        let model = makeModel()
        _ = try importItem(model, title: "Any Article", margin: "A Margin.")

        await model.openBatchExport(scopedTo: nil).value

        XCTAssertEqual(model.screen, .batchExport)
        XCTAssertTrue(model.selectedBatchExportSessionIds.isEmpty)
    }

    func testExportSessionsReopenedWithoutAScopeDropsEarlierSelection() async throws {
        let model = makeModel()
        let first = try importItem(model, title: "Course Reading One", margin: "A Margin.")
        let collection = ItemCollection(id: "collection-a", name: "A", itemIDs: [first.itemID], createdAt: Date())
        try save(collection, in: model)
        await model.openBatchExport(scopedTo: ItemCollectionScope(collection)).value
        XCTAssertEqual(model.selectedBatchExportSessionIds, [first.sessionID])

        await model.openBatchExport(scopedTo: nil).value

        XCTAssertTrue(model.selectedBatchExportSessionIds.isEmpty)
    }

    /// Export Sessions reads its rows off the main actor (#2507): a second tap before the first read comes back
    /// must leave the second's result, not the first's selection.
    func testOpeningExportSessionsTwiceInARowKeepsTheNewestOpen() async throws {
        let model = makeModel()
        let first = try importItem(model, title: "Course Reading One", margin: "A Margin.")
        let collection = ItemCollection(id: "collection-a", name: "A", itemIDs: [first.itemID], createdAt: Date())
        try save(collection, in: model)

        let scoped = model.openBatchExport(scopedTo: ItemCollectionScope(collection))
        let unscoped = model.openBatchExport(scopedTo: nil)
        await scoped.value
        await unscoped.value

        XCTAssertEqual(model.screen, .batchExport)
        XCTAssertTrue(model.selectedBatchExportSessionIds.isEmpty, "the older open was cancelled, so its selection never lands")
        XCTAssertEqual(model.batchExportRows.map(\.id), [first.sessionID])
    }

    func testDeletingACollectionKeepsItsItemsSessionsAndMargins() throws {
        let model = makeModel()
        let first = try importItem(model, title: "Course Reading One", margin: "Margin on the first reading.")
        let second = try importItem(model, title: "Course Reading Two", margin: "Margin on the second reading.")
        let store = try XCTUnwrap(model.store)
        let other = ItemCollection(id: "collection-other", name: "Other", itemIDs: [first.itemID], createdAt: Date())
        let doomed = ItemCollection(id: "collection-doomed", name: "HIST 210",
                                    itemIDs: [first.itemID, second.itemID], createdAt: Date().addingTimeInterval(1))
        try save(other, in: model)
        try save(doomed, in: model)
        model.refreshMarginRows()
        model.marginCollectionQuery.selectScope(tag: MarginCollectionQuery.collectionTagPrefix + doomed.id,
                                                collections: try store.loadItemCollections())
        XCTAssertEqual(Set(model.visiblePrivateMarginRows.map(\.interjection.sessionId)), [first.sessionID, second.sessionID])
        let itemsBefore = Set(try store.listItems().map(\.id))
        let marginsBefore = Set(try store.loadInterjections(sessionId: first.sessionID).map(\.id)
            + store.loadInterjections(sessionId: second.sessionID).map(\.id))
        XCTAssertEqual(marginsBefore.count, 2)

        try store.deleteItemCollection(id: doomed.id)
        let remaining = try store.loadItemCollections()
        model.marginCollectionQuery.refreshCollection(from: remaining)
        model.refreshMarginRows()

        XCTAssertEqual(remaining.map(\.id), [other.id], "only the deleted collection goes; another keeps its items")
        XCTAssertEqual(remaining.first?.itemIDs, [first.itemID])
        XCTAssertEqual(Set(try store.listItems().map(\.id)), itemsBefore, "items are untouched")
        XCTAssertEqual(Set(try store.loadInterjections(sessionId: first.sessionID).map(\.id)
            + store.loadInterjections(sessionId: second.sessionID).map(\.id)), marginsBefore, "Margins are untouched")
        XCTAssertNil(model.marginCollectionQuery.collection, "a scope on the deleted collection falls back to all items")
        XCTAssertEqual(Set(model.visiblePrivateMarginRows.map(\.interjection.sessionId)), [first.sessionID, second.sessionID],
                       "with the scope gone, every Margin is listed again")
    }
}
