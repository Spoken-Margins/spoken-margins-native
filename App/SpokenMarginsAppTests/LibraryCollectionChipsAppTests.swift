import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// App-hosted checks for the Library's collection chips (#4343, PR 2): a collection made from the New collection sheet's
/// model narrows the model's Library list, All lists everything, and deleting a collection keeps every item.
@MainActor
final class LibraryCollectionChipsAppTests: XCTestCase {
    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        return model
    }

    /// Imports `count` text items and returns their ids in the Library's order.
    private func importItems(_ model: Gate1AppModel, count: Int) throws -> [String] {
        var ids: [String] = []
        for number in 1...count {
            model.importTitle = "Reading \(number)"
            model.importText = "Source text for reading \(number)."
            model.importTextItem()
            model.pause()
            ids.append(model.selectedItem.id)
        }
        try model.refreshLibraryRows(store: try XCTUnwrap(model.store))
        return ids
    }

    func testACollectionNarrowsTheLibraryAllListsEverythingAndDeleteKeepsEveryItem() async throws {
        let model = makeModel()
        let ids = try importItems(model, count: 16)
        let store = try XCTUnwrap(model.store)
        // The seeded fixture item is in the Library too, so "everything" is whatever the Library lists before a collection.
        let itemsBefore = Set(try store.listItems().map(\.id))
        let everything = Set(model.visibleLibraryItems.map(\.id))
        XCTAssertTrue(everything.isSuperset(of: ids))
        XCTAssertTrue(CollectionChipRule.showsRow(itemCount: model.libraryItems.count, collectionCount: 0), "16 or more items show the row")

        guard case .saved = await model.libraryCollections.create(name: "HIST 210", itemIDs: Array(ids.prefix(3)), store: store) else {
            return XCTFail("the collection should save")
        }

        let made = try XCTUnwrap(model.libraryCollections.collections.first)
        XCTAssertEqual(model.libraryCollections.selection?.collectionID, made.id, "a new collection is selected")
        XCTAssertEqual(Set(model.visibleLibraryItems.map(\.id)), Set(ids.prefix(3)), "the list shows only HIST 210's items")
        XCTAssertEqual(try store.loadItemCollections().map(\.name), ["HIST 210"], "the collection is stored")

        model.libraryCollections.select(collectionID: nil)
        XCTAssertEqual(Set(model.visibleLibraryItems.map(\.id)), everything, "All shows everything")

        model.libraryCollections.select(collectionID: made.id)
        guard case .saved = await model.libraryCollections.delete(made, store: store) else { return XCTFail("the delete should save") }
        XCTAssertNil(model.libraryCollections.selection, "a deleted selected collection falls back to All")
        XCTAssertEqual(Set(model.visibleLibraryItems.map(\.id)), everything, "delete keeps every item")
        XCTAssertEqual(Set(try store.listItems().map(\.id)), itemsBefore, "items are untouched in the store")
        XCTAssertTrue(try store.loadItemCollections().isEmpty)
    }

    func testTheLibraryReadBringsTheCollectionsWithTheRowsAndALaunchOpensOnAll() async throws {
        let model = makeModel()
        let ids = try importItems(model, count: 3)
        let store = try XCTUnwrap(model.store)
        try store.saveItemCollection(ItemCollection(id: "collection-a", name: "A", itemIDs: [ids[0]], createdAt: Date()))
        XCTAssertTrue(model.libraryCollections.collections.isEmpty, "nothing has read the store since the save")

        try model.refreshLibraryRows(store: store)

        XCTAssertEqual(model.libraryCollections.collections.map(\.id), ["collection-a"], "read with the Library rows")
        XCTAssertNil(model.libraryCollections.selection, "the selection is never restored: every launch opens on All")
    }

    func testAnEmptyCollectionAndADoubleCreate() async throws {
        let model = makeModel()
        _ = try importItems(model, count: 2)
        let store = try XCTUnwrap(model.store)

        guard case .saved = await model.libraryCollections.create(name: "Empty", itemIDs: [], store: store) else { return XCTFail() }
        XCTAssertEqual(
            LibraryCollectionScope.screenState(
                accessError: nil, rows: model.libraryItems, query: model.libraryQuery, in: model.libraryCollections.selection),
            .emptyCollection)

        if case .nameTaken = await model.libraryCollections.create(name: " empty ", itemIDs: [], store: store) {} else {
            XCTFail("a second create with the same name makes no second collection")
        }
        XCTAssertEqual(try store.loadItemCollections().count, 1)
    }
}
