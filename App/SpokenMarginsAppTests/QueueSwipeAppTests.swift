import SessionKitPersistence
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4044: Add to Queue by swipe. The taps go through the real model: a row in the Library toggles the queue, and a row that
/// is not in the Library yet saves first and queues once the import lands.
@MainActor
final class QueueSwipeAppTests: XCTestCase {
    private func makeModel() throws -> (Gate1AppModel, SQLiteSessionStore) {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        PlayQueueController.update(model) { $0.clear() }
        let store = try model.requireStore()
        for id in ["swipe-a", "swipe-b"] {
            try store.saveItem(Item(id: id, title: "Title \(id)", mediaType: "text", text: "One.\n\nTwo.", externalReference: nil, status: "Ready"))
        }
        try model.refreshLibraryRows(store: store)
        return (model, store)
    }

    private var queuedIds: [String] { PlayQueueState.shared.itemIds }

    func testTheRowButtonFlipsBetweenAddAndRemoveAsTheQueueChanges() throws {
        let (model, _) = try makeModel()
        XCTAssertEqual(QueueRowAction.action(forItem: "swipe-a", queuedItemIds: queuedIds).title, "Add to Queue")
        model.toggleQueue(itemId: "swipe-a")
        XCTAssertEqual(queuedIds, ["swipe-a"])
        XCTAssertEqual(model.statusMessage, "Added Title swipe-a to the queue.")
        XCTAssertEqual(QueueRowAction.action(forItem: "swipe-a", queuedItemIds: queuedIds).title, "Remove from Queue")
        XCTAssertEqual(QueueRowAction.action(forItem: "swipe-b", queuedItemIds: queuedIds).title, "Add to Queue", "another row is unaffected")
        model.toggleQueue(itemId: "swipe-a")
        XCTAssertEqual(queuedIds, [])
        XCTAssertEqual(model.statusMessage, "Removed Title swipe-a from the queue.")
        XCTAssertEqual(QueueRowAction.action(forItem: "swipe-a", queuedItemIds: queuedIds).title, "Add to Queue")
    }

    func testAStaleRowStillDoesTheRightThing() throws {
        // A row drawn when the item was not queued, tapped after another row queued it: the tap reads the queue now.
        let (model, _) = try makeModel()
        model.queueAppend(itemId: "swipe-a")
        model.toggleQueue(itemId: "swipe-a")
        XCTAssertEqual(queuedIds, [], "the stale Add to Queue tap removed it instead of leaving it queued twice")
    }

    func testASavedEpisodeIsQueuedOnceWhenItsImportLands() throws {
        let (model, _) = try makeModel()
        QueueWishController.register("entry-saved")
        model.settleQueueWish(key: "entry-saved", itemId: "swipe-a")
        XCTAssertEqual(queuedIds, ["swipe-a"])
        XCTAssertEqual(model.statusMessage, "Added Title swipe-a to the Library and the queue.")
        model.settleQueueWish(key: "entry-saved", itemId: "swipe-a")
        XCTAssertEqual(queuedIds, ["swipe-a"], "the wish is spent")
    }

    func testAFailedImportQueuesNothing() throws {
        let (model, _) = try makeModel()
        QueueWishController.register("entry-failed")
        model.settleQueueWish(key: "entry-failed", itemId: nil)
        XCTAssertEqual(queuedIds, [])
    }

    func testAnImportWithNoWishQueuesNothing() throws {
        let (model, _) = try makeModel()
        model.settleQueueWish(key: "entry-add-only", itemId: "swipe-a")
        XCTAssertEqual(queuedIds, [], "the listener only tapped Add")
    }

    func testAnItemDeletedBeforeTheWishIsReleasedIsDropped() throws {
        let (model, store) = try makeModel()
        QueueWishController.register("entry-deleted")
        try store.deleteItem(id: "swipe-a")
        try model.refreshLibraryRows(store: store)
        model.settleQueueWish(key: "entry-deleted", itemId: "swipe-a")
        XCTAssertEqual(queuedIds, [])
    }

    func testTwoRowsQueuedBackToBackReachTheQueueInTapOrder() throws {
        let (model, _) = try makeModel()
        QueueWishController.register("entry-first")
        QueueWishController.register("entry-second")
        model.settleQueueWish(key: "entry-second", itemId: "swipe-b")
        XCTAssertEqual(queuedIds, [], "the second row waits for the first")
        model.settleQueueWish(key: "entry-first", itemId: "swipe-a")
        XCTAssertEqual(queuedIds, ["swipe-a", "swipe-b"])
    }
}
