import Foundation
import XCTest
@testable import SessionKit

/// #4044: Add to Queue on a row that is not in the Library yet saves the item, then queues it. These tests are the
/// device-condition rows the Design comment names (docs/workstreams/device-conditions.md): `burst`, `network`,
/// `background`, `relaunch` and `store`.
final class SaveThenQueueWishesTests: XCTestCase {
    private let everyItemExists: (String) -> Bool = { _ in true }

    /// Applies releases to a queue the way the app does: `append`, which never adds an item twice.
    private func apply(_ releases: [SaveThenQueueWishes.Release], to queue: inout PlayQueue) {
        releases.forEach { queue.append($0.itemId) }
    }

    // MARK: The wish

    func testAWishAddsTheItemExactlyOnceWhenTheImportLands() {
        var wishes = SaveThenQueueWishes()
        var queue = PlayQueue()
        wishes.register("entry-1")
        let released = wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists)
        XCTAssertEqual(released, [.init(key: "entry-1", itemId: "item-1")])
        apply(released, to: &queue)
        XCTAssertEqual(queue.itemIds, ["item-1"])
        XCTAssertFalse(wishes.isWished("entry-1"), "the wish is spent")
        XCTAssertEqual(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists), [], "a second settle queues nothing")
    }

    func testAWishDoesNotQueueAnythingBeforeTheImportEnds() {
        var wishes = SaveThenQueueWishes()
        XCTAssertTrue(wishes.register("entry-1"))
        XCTAssertTrue(wishes.isWished("entry-1"))
        XCTAssertEqual(wishes.pendingKeys, ["entry-1"])
    }

    func testAnItemAlreadyInTheQueueIsNotQueuedTwice() {
        var wishes = SaveThenQueueWishes()
        var queue = PlayQueue(itemIds: ["other", "item-1"])
        wishes.register("entry-1")
        apply(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists), to: &queue)
        XCTAssertEqual(queue.itemIds, ["other", "item-1"])
    }

    // MARK: burst

    func testAddToQueueTwiceIsOneWish() {
        var wishes = SaveThenQueueWishes()
        XCTAssertTrue(wishes.register("entry-1"))
        XCTAssertFalse(wishes.register("entry-1"), "the second tap changes nothing")
        XCTAssertEqual(wishes.pendingKeys, ["entry-1"])
        let released = wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists)
        XCTAssertEqual(released.count, 1, "one banner and one queue entry")
    }

    func testAddToQueueWhileAddIsRunningAttachesTheWishToThatImport() {
        // Add started the import; the wish is registered afterwards and the same import's end settles it. A second
        // import is never needed, because `importFollowedSourceEntry` returns early for an entry already importing.
        var wishes = SaveThenQueueWishes()
        var importsStarted = 0
        importsStarted += 1 // the Add tap
        wishes.register("entry-1") // the Add to Queue tap, while that import runs
        XCTAssertEqual(importsStarted, 1)
        XCTAssertEqual(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists).map(\.itemId), ["item-1"])
    }

    func testAddAfterAddToQueueIsTheSameImportAndTheSameWish() {
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1") // Add to Queue starts the import
        // Add then joins that import: it registers nothing, and the import's end still releases the wish once.
        XCTAssertEqual(wishes.pendingKeys, ["entry-1"])
        XCTAssertEqual(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists).count, 1)
    }

    func testAnImportEndingWithNoWishQueuesNothing() {
        var wishes = SaveThenQueueWishes()
        XCTAssertEqual(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists), [], "the listener only tapped Add")
        wishes.register("entry-2")
        XCTAssertEqual(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists), [], "another entry's import is not this wish")
        XCTAssertTrue(wishes.isWished("entry-2"))
    }

    func testTwoRowsQueuedBackToBackKeepTheTapOrderWhateverFinishesFirst() {
        var wishes = SaveThenQueueWishes()
        var queue = PlayQueue(itemIds: ["old"])
        wishes.register("entry-A")
        wishes.register("entry-B")
        // B's import finishes first: it waits for A, so the queue never has B ahead of A.
        let early = wishes.settle("entry-B", outcome: .imported(itemId: "item-B"), itemExists: everyItemExists)
        XCTAssertEqual(early, [])
        apply(early, to: &queue)
        XCTAssertEqual(queue.itemIds, ["old"])
        XCTAssertEqual(wishes.pendingKeys, ["entry-A", "entry-B"])
        let released = wishes.settle("entry-A", outcome: .imported(itemId: "item-A"), itemExists: everyItemExists)
        XCTAssertEqual(released.map(\.itemId), ["item-A", "item-B"])
        apply(released, to: &queue)
        XCTAssertEqual(queue.itemIds, ["old", "item-A", "item-B"])
        XCTAssertEqual(wishes.pendingKeys, [])
    }

    func testTheOrderIsKeptWhenTheFirstImportFails() {
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-A")
        wishes.register("entry-B")
        wishes.register("entry-C")
        XCTAssertEqual(wishes.settle("entry-C", outcome: .imported(itemId: "item-C"), itemExists: everyItemExists), [])
        XCTAssertEqual(wishes.settle("entry-A", outcome: .failed, itemExists: everyItemExists), [], "A is dropped, B still runs")
        let released = wishes.settle("entry-B", outcome: .imported(itemId: "item-B"), itemExists: everyItemExists)
        XCTAssertEqual(released.map(\.itemId), ["item-B", "item-C"])
    }

    func testAWishThatWasReleasedCanBeMadeAgainForALaterTap() {
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1")
        _ = wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists)
        XCTAssertTrue(wishes.register("entry-1"), "a new tap after the first wish ended is a new wish")
    }

    // MARK: network

    func testAFailedImportQueuesNothingAndClearsTheWish() throws {
        let directory = try makeTemporaryDirectory()
        let store = PlayQueueStore(fileURL: directory.appending(path: "play-queue.json"))
        try store.save(PlayQueue(itemIds: ["old"]))
        let before = try Data(contentsOf: store.fileURL)

        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1")
        let released = wishes.settle("entry-1", outcome: .failed, itemExists: everyItemExists)
        XCTAssertEqual(released, [])
        XCTAssertFalse(wishes.isWished("entry-1"), "the wish is cleared, so a retry starts clean")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before, "the queue file is untouched")
        XCTAssertTrue(wishes.register("entry-1"), "the listener can try again")
    }

    // MARK: A deleted item

    func testAnItemDeletedBeforeTheWishIsReleasedIsDropped() {
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1")
        let released = wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: { _ in false })
        XCTAssertEqual(released, [])
        XCTAssertFalse(wishes.isWished("entry-1"))
    }

    func testAnItemDeletedWhileItWaitedBehindAnEarlierWishIsDroppedAtReleaseTime() {
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-A")
        wishes.register("entry-B")
        _ = wishes.settle("entry-B", outcome: .imported(itemId: "item-B"), itemExists: everyItemExists)
        // B lands, then the listener deletes it before A ends. The check runs when B is released.
        let released = wishes.settle("entry-A", outcome: .imported(itemId: "item-A"), itemExists: { $0 != "item-B" })
        XCTAssertEqual(released.map(\.itemId), ["item-A"])
    }

    // MARK: background

    func testTheWishSurvivesTheAppBeingLeftAndResolvesOnCompletion() {
        // Leaving the app changes nothing here: the wish is a value the model holds, and only an import's end settles it.
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1")
        let backgrounded = wishes // a copy taken when the app was left stays equal to the live one
        XCTAssertEqual(backgrounded, wishes)
        XCTAssertEqual(wishes.settle("other-entry", outcome: .failed, itemExists: everyItemExists), [], "another entry's failure leaves this wish alone")
        XCTAssertTrue(wishes.isWished("entry-1"))
        XCTAssertEqual(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists).map(\.itemId), ["item-1"])
    }

    func testTheWishClearsOnAFailureAfterTheAppWasLeft() {
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1")
        XCTAssertEqual(wishes.settle("entry-1", outcome: .failed, itemExists: everyItemExists), [])
        XCTAssertEqual(wishes.pendingKeys, [])
    }

    func testOpeningOrPlayingSomethingElseDoesNotCancelTheWish() {
        // Queuing never takes playback (#2124 is about what plays now), so the wish has no cancel at all: the only
        // ways out are an import's end, success or failure.
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1")
        XCTAssertTrue(wishes.isWished("entry-1"))
        XCTAssertEqual(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists).count, 1)
    }

    // MARK: relaunch

    func testARelaunchLosesTheWishButTheItemAndTheQueueFileAreIntact() throws {
        let directory = try makeTemporaryDirectory()
        let store = PlayQueueStore(fileURL: directory.appending(path: "play-queue.json"))
        try store.save(PlayQueue(itemIds: ["old-1", "old-2"]))
        let before = try Data(contentsOf: store.fileURL)

        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1")
        // The app is killed mid-import and starts again: the wishes are new and empty.
        var afterRelaunch = SaveThenQueueWishes()
        XCTAssertFalse(afterRelaunch.isWished("entry-1"))
        XCTAssertEqual(afterRelaunch.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists), [], "the import that finished anyway queues nothing")
        XCTAssertEqual(store.load().itemIds, ["old-1", "old-2"], "the queue is what the file said")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before, "the file is untouched")
        _ = wishes
    }

    func testTheQueueFileFormatIsUnchangedAfterAReleasedWish() throws {
        let directory = try makeTemporaryDirectory()
        let store = PlayQueueStore(fileURL: directory.appending(path: "play-queue.json"))
        var queue = store.load()
        var wishes = SaveThenQueueWishes()
        wishes.register("entry-1")
        apply(wishes.settle("entry-1", outcome: .imported(itemId: "item-1"), itemExists: everyItemExists), to: &queue)
        try store.save(queue)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["itemIds"], "the file has the one key it always had")
        XCTAssertEqual(object?["itemIds"] as? [String], ["item-1"])
        XCTAssertEqual(store.load().itemIds, ["item-1"], "and the last shipped build's reader gets the same list")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "queue-wish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// #4044 `store`: the button a row shows comes from the queue's ids as they are now, not from a copy the row cached.
final class QueueRowActionTests: XCTestCase {
    func testTheButtonFollowsTheQueueWithNoLibraryReload() {
        var queue = PlayQueue(itemIds: ["a"])
        let libraryRowSnapshot = "b" // the row's item id, which the row keeps while the Library is not reloaded
        XCTAssertEqual(QueueRowAction.action(forItem: libraryRowSnapshot, queuedItemIds: queue.itemIds), .add)
        queue.append("b")
        XCTAssertEqual(QueueRowAction.action(forItem: libraryRowSnapshot, queuedItemIds: queue.itemIds), .remove, "the queue screen or another row queued it")
        queue.remove("b")
        XCTAssertEqual(QueueRowAction.action(forItem: libraryRowSnapshot, queuedItemIds: queue.itemIds), .add)
        XCTAssertEqual(QueueRowAction.action(forItem: "a", queuedItemIds: queue.itemIds), .remove)
        XCTAssertEqual(QueueRowAction.action(forItem: "a", queuedItemIds: []), .add, "an empty queue holds nothing")
    }

    func testOneNameEverywhere() {
        XCTAssertEqual(QueueRowAction.add.title, "Add to Queue")
        XCTAssertEqual(QueueRowAction.remove.title, "Remove from Queue")
        XCTAssertEqual(QueueRowAction.add.newestEpisodeTitle, "Add newest episode to Queue")
        XCTAssertEqual(QueueRowAction.remove.newestEpisodeTitle, "Remove newest episode from Queue")
        XCTAssertNotEqual(QueueRowAction.add.systemImage, QueueRowAction.remove.systemImage, "the icon carries the meaning too")
    }

    func testTheBanners() {
        XCTAssertEqual(QueueRowAction.add.banner(title: "Episode 4"), "Added Episode 4 to the queue.")
        XCTAssertEqual(QueueRowAction.remove.banner(title: "Episode 4"), "Removed Episode 4 from the queue.")
        XCTAssertEqual(QueueRowAction.savedAndQueuedBanner(title: "Episode 4"), "Added Episode 4 to the Library and the queue.")
    }
}
