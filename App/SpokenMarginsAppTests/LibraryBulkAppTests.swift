import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// App-hosted checks for the Library's collections and Select (#3769, #4720), on the model functions the screens call:
/// a Select delete's one Undo restores every item it moved, ticked rows made into a new collection keep their order,
/// deleting a collection keeps every item, and a collection save stales a Library read already in flight.
@MainActor
final class LibraryBulkAppTests: XCTestCase {
    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        return model
    }

    /// Imports `count` text items and returns their ids in import order.
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

    private func isTrashed(_ id: String, _ store: SQLiteSessionStore) throws -> Bool {
        try XCTUnwrap(try store.loadItemSummary(id: id)).deletedAt != nil
    }

    func testABulkDeleteOffersOneUndoThatRestoresEveryItem() throws {
        let model = makeModel()
        let ids = try importItems(model, count: 4)
        let store = try XCTUnwrap(model.store)
        let ticked = Array(ids.prefix(3))

        model.moveItemsToTrash(ticked)

        for id in ticked { XCTAssertTrue(try isTrashed(id, store), "\(id) is in Recently Deleted") }
        XCTAssertFalse(try isTrashed(ids[3], store), "an unticked item stays")
        XCTAssertEqual(model.trashUndo?.itemIds, ticked, "one Undo holds every moved item")
        XCTAssertEqual(model.trashUndo?.title, "3 items")
        XCTAssertEqual(model.statusMessage, "Moved 3 items to Recently Deleted.")

        model.undoLastTrash()

        for id in ticked { XCTAssertFalse(try isTrashed(id, store), "\(id) is back") }
        XCTAssertNil(model.trashUndo)
        XCTAssertEqual(model.statusMessage, "Restored 3 items.")
    }

    /// A mixed selection's Mark as Finished, then Undo, puts back exactly the items it changed: the ones finished before
    /// stay finished (#4720, #4733 audit). Mark as Unfinished's Undo re-finishes them at their earlier time.
    func testBulkMarkUndoTakesBackOnlyTheItemsItChanged() async throws {
        let model = makeModel()
        let ids = try importItems(model, count: 5)
        let store = try XCTUnwrap(model.store)
        func finishedAt(_ id: String) throws -> Date? { try store.loadItem(id: id).sourceCompletedAt }
        let early = try XCTUnwrap(ManualItemCompletion.markComplete(itemId: ids[0], in: store)?.sourceCompletedAt)
        _ = try ManualItemCompletion.markComplete(itemId: ids[1], in: store)

        model.markItemsFinished(ids)
        try await pollUntil { model.feedbackEvent?.message == "Marked 3 items as finished." }
        XCTAssertEqual(model.feedbackEvent?.message, "Marked 3 items as finished.")
        for id in ids { XCTAssertNotNil(try finishedAt(id), "\(id) finished") }
        let undo = try XCTUnwrap(model.feedbackEvent?.action, "the banner offers Undo")
        XCTAssertEqual(undo.title, "Undo")

        undo.perform()
        try await pollUntil { model.feedbackEvent?.message == "Marked 3 items as unfinished." }
        XCTAssertEqual(try finishedAt(ids[0]), early, "finished before the action: still finished, same time")
        XCTAssertNotNil(try finishedAt(ids[1]))
        for id in ids[2...] { XCTAssertNil(try finishedAt(id), "\(id) is unfinished again") }

        model.markItemsUnfinished(ids)
        try await pollUntil { model.feedbackEvent?.message == "Marked 2 items as unfinished." }
        XCTAssertNil(try finishedAt(ids[0]))
        try XCTUnwrap(model.feedbackEvent?.action).perform()
        try await pollUntil { model.feedbackEvent?.message == "Marked 2 items as finished." }
        XCTAssertEqual(try finishedAt(ids[0]), early, "re-finished at the time it was finished before")
        for id in ids[2...] { XCTAssertNil(try finishedAt(id), "never finished, so Undo leaves \(id) alone") }
    }

    func testARowDeleteStillUndoesItsOneItem() throws {
        let model = makeModel()
        let ids = try importItems(model, count: 2)
        let store = try XCTUnwrap(model.store)

        model.moveItemToTrash(id: ids[0])
        XCTAssertEqual(model.trashUndo?.itemIds, [ids[0]])
        model.undoLastTrash()
        XCTAssertFalse(try isTrashed(ids[0], store))
        XCTAssertEqual(model.statusMessage, "Restored Reading 1.")
    }

    func testTickedRowsMakeANewCollectionInTheirOrderAndAnExistingOneTakesOnlyNewItems() async throws {
        let model = makeModel()
        let ids = try importItems(model, count: 4)
        let store = try XCTUnwrap(model.store)
        let ticked = [ids[2], ids[0]]

        let refusal = await model.addItems(ticked, toNewCollectionNamed: "  Week 3  ")

        XCTAssertNil(refusal)
        let made = try XCTUnwrap(try store.loadItemCollections().first { $0.name == "Week 3" })
        XCTAssertEqual(made.itemIDs, ticked, "the new collection holds the ticked items in the view's order")
        XCTAssertEqual(model.statusMessage, "Made “Week 3” with 2 items.")

        let again = await model.addItems(ids, toNewCollectionNamed: "week 3")
        XCTAssertEqual(again, ItemCollectionEditing.Wording.nameTaken, "a taken name is refused in the sheet")

        let current = try XCTUnwrap(model.libraryCollections.collections.first { $0.id == made.id })
        let saved = await model.addItems([ids[0], ids[3]], toCollection: current)
        XCTAssertTrue(saved)
        XCTAssertEqual(try store.loadItemCollections().first { $0.id == made.id }?.itemIDs, [ids[2], ids[0], ids[3]])
        XCTAssertEqual(model.statusMessage, "Added 1 item to “Week 3”. 1 was already in it.")
    }

    func testRemoveFromCollectionAndDeleteCollectionKeepEveryItem() async throws {
        let model = makeModel()
        let ids = try importItems(model, count: 3)
        let store = try XCTUnwrap(model.store)
        let itemsBefore = Set(try store.listItems().map(\.id))
        let refusal = await model.addItems(ids, toNewCollectionNamed: "Course")
        XCTAssertNil(refusal)
        let made = try XCTUnwrap(model.libraryCollections.collections.first { $0.name == "Course" })

        await model.removeItems([ids[1]], fromCollection: made)
        XCTAssertEqual(try store.loadItemCollections().first { $0.id == made.id }?.itemIDs, [ids[0], ids[2]])

        let deleted = await model.deleteCollection(collectionID: made.id)
        XCTAssertTrue(deleted)
        XCTAssertTrue(try store.loadItemCollections().isEmpty)
        XCTAssertEqual(Set(try store.listItems().map(\.id)), itemsBefore, "items are untouched in the store")
    }

    func testACollectionSaveOrDeleteStalesALibraryReadAlreadyInFlight() async throws {
        let model = makeModel()
        _ = try importItems(model, count: 2)
        let store = try XCTUnwrap(model.store)
        let before = model.libraryPresentationRevision

        guard case .saved = await model.libraryCollections.create(name: "A", itemIDs: [], store: store) else { return XCTFail() }
        XCTAssertGreaterThan(model.libraryPresentationRevision, before, "a read begun before the save must be read again")

        let afterCreate = model.libraryPresentationRevision
        let made = try XCTUnwrap(model.libraryCollections.collections.first)
        guard case .saved = await model.libraryCollections.delete(made, store: store) else { return XCTFail() }
        XCTAssertGreaterThan(model.libraryPresentationRevision, afterCreate)
    }
}
