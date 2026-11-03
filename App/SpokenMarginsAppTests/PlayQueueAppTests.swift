import SessionKitPersistence
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #1990: "Play Next" and "Add to Queue" feed a queue, and the next queued item starts when the playing one finishes.
@MainActor
final class PlayQueueAppTests: XCTestCase {
    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        PlayQueueController.update(model) { $0.clear() }
        return model
    }

    func testPlayNextGoesAheadOfWhatWasAlreadyQueued() {
        let model = makeModel()
        model.queueAppend(itemId: "item-pill")
        model.queuePlayNext(itemId: Gate1AppModel.welcomeSampleItemId)
        XCTAssertEqual(PlayQueueController.current(model).itemIds, [Gate1AppModel.welcomeSampleItemId, "item-pill"])
    }

    func testFinishingTheItemPlayingStartsTheNextQueuedItem() async throws {
        let model = makeModel()
        model.addSampleItem()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        model.queueAppend(itemId: Gate1AppModel.welcomeSampleItemId)

        var before = model.snapshot
        before.phase = .itemPlayback
        var after = before
        after.phase = .finished
        XCTAssertEqual(after.sessionId, sessionId)
        model.playQueueSnapshotChanged(from: before, to: after)
        await Task.yield()

        XCTAssertEqual(model.snapshot.itemId, Gate1AppModel.welcomeSampleItemId)
        XCTAssertTrue(PlayQueueController.current(model).isEmpty, "the started item leaves the queue")
    }

    /// Verification of #1990 (Done when 3): three queued items play one after another through the real model. Each hop is
    /// the finish edge of the session that is actually playing, so a hop that started the wrong item, started two, or did
    /// not leave the queue would show here. A queued item deleted from the Library in between is skipped.
    func testThreeQueuedItemsPlayInOrderAndADeletedOneIsSkipped() async throws {
        let model = makeModel()
        model.addSampleItem()
        let store = try model.requireStore()
        for id in ["queue-third", "queue-gone"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "One.\n\nTwo.", externalReference: nil, status: "Ready"))
        }
        try model.refreshLibraryRows(store: store)
        let first = "item-pill", second = Gate1AppModel.welcomeSampleItemId, third = "queue-third"
        model.startItem(id: first)
        model.queueAppend(itemId: second)
        model.queueAppend(itemId: "queue-gone")
        model.queueAppend(itemId: third)
        try store.deleteItem(id: "queue-gone")
        try model.refreshLibraryRows(store: store)

        var played = [try XCTUnwrap(model.snapshot.itemId)]
        for _ in 0..<2 {
            var before = model.snapshot
            before.phase = .itemPlayback
            var after = before
            after.phase = .finished
            model.playQueueSnapshotChanged(from: before, to: after)
            await Task.yield()
            await Task.yield()
            played.append(try XCTUnwrap(model.snapshot.itemId))
        }
        XCTAssertEqual(played, [first, second, third])
        XCTAssertTrue(PlayQueueController.current(model).isEmpty, "every started item left the queue")

        // The queue is now empty: the third item finishing starts nothing.
        var before = model.snapshot
        before.phase = .itemPlayback
        var after = before
        after.phase = .finished
        model.playQueueSnapshotChanged(from: before, to: after)
        await Task.yield()
        XCTAssertEqual(model.snapshot.itemId, third)
    }

    /// The sleep timer ends the whole run (the Default taken on #1990): a finish while it runs starts nothing and the
    /// queue keeps its items.
    func testAFinishWhileTheSleepTimerRunsStartsNothingAndKeepsTheQueue() async throws {
        let model = makeModel()
        model.addSampleItem()
        model.startItem(id: "item-pill")
        model.queueAppend(itemId: Gate1AppModel.welcomeSampleItemId)
        model.armSleepTimer(.minutes15)
        defer { model.cancelSleepTimer() }
        XCTAssertTrue(model.sleepTimerIsActive)

        var before = model.snapshot
        before.phase = .itemPlayback
        var after = before
        after.phase = .finished
        model.playQueueSnapshotChanged(from: before, to: after)
        await Task.yield()

        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertEqual(PlayQueueController.current(model).itemIds, [Gate1AppModel.welcomeSampleItemId])
    }

    func testNothingStartsWhenTheQueueIsEmpty() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        var before = model.snapshot
        before.phase = .itemPlayback
        var after = before
        after.phase = .finished
        model.playQueueSnapshotChanged(from: before, to: after)
        await Task.yield()
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
    }

    // The queue screen's edits (#1990).

    func testReorderingTheScreenRowsMovesTheRightItemEvenWithADeletedOneQueued() {
        let model = makeModel()
        model.addSampleItem()
        let welcome = Gate1AppModel.welcomeSampleItemId
        PlayQueueController.update(model) { queue in
            queue.append("deleted-item")
            queue.append(welcome)
            queue.append("item-pill")
        }
        // The screen shows [welcome, item-pill]; dragging row 1 to the top.
        model.moveInQueue(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(PlayQueueController.current(model).itemIds, ["item-pill", welcome])
        XCTAssertEqual(PlayQueueState.shared.itemIds, ["item-pill", welcome], "the screen follows the queue")
    }

    func testRemovingAndClearingTheQueueFromTheScreen() {
        let model = makeModel()
        model.queueAppend(itemId: "item-pill")
        model.queueAppend(itemId: Gate1AppModel.welcomeSampleItemId)
        model.removeFromQueue(itemId: "item-pill")
        XCTAssertEqual(PlayQueueController.current(model).itemIds, [Gate1AppModel.welcomeSampleItemId])
        model.clearPlayQueue()
        XCTAssertTrue(PlayQueueController.current(model).isEmpty)
        XCTAssertTrue(PlayQueueState.shared.itemIds.isEmpty)
    }

    func testPlayingAQueuedRowNowStartsItAndTakesItOutOfTheQueue() {
        let model = makeModel()
        model.addSampleItem()
        model.queueAppend(itemId: "item-pill")
        model.queueAppend(itemId: Gate1AppModel.welcomeSampleItemId)
        model.playQueuedItemNow(itemId: Gate1AppModel.welcomeSampleItemId)
        XCTAssertEqual(model.snapshot.itemId, Gate1AppModel.welcomeSampleItemId)
        XCTAssertEqual(PlayQueueController.current(model).itemIds, ["item-pill"])
    }
}
