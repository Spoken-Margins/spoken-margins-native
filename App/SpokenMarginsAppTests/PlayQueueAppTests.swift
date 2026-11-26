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

    /// #4227: permanent delete took the item's rows and files but left its id in the queue's file until the next reorder or
    /// advance, so the same item imported again (a packet's id is deterministic) came back into the queue. Single and
    /// bulk delete both take the id out of the queue and its file; an item that is not deleted keeps its place.
    func testPermanentDeleteTakesTheItemOutOfTheQueueAndItsFile() throws {
        let model = makeModel()
        model.queueAppend(itemId: "item-pill")
        model.queueAppend(itemId: Gate1AppModel.welcomeSampleItemId)
        model.moveItemToTrash(id: "item-pill")
        XCTAssertEqual(PlayQueueController.current(model).itemIds, ["item-pill", Gate1AppModel.welcomeSampleItemId])

        model.permanentlyDeleteItem(id: "item-pill")

        XCTAssertEqual(PlayQueueController.current(model).itemIds, [Gate1AppModel.welcomeSampleItemId])
        let file = try model.applicationSupportDirectory().appending(path: "play-queue.json")
        XCTAssertEqual(PlayQueueStore(fileURL: file).load().itemIds, [Gate1AppModel.welcomeSampleItemId])
    }

    func testEmptyRecentlyDeletedTakesEveryDeletedItemOutOfTheQueue() {
        let model = makeModel()
        model.queueAppend(itemId: "item-pill")
        model.queueAppend(itemId: Gate1AppModel.welcomeSampleItemId)
        model.moveItemToTrash(id: "item-pill")

        model.permanentlyDeleteRecentlyDeletedItems()

        XCTAssertEqual(PlayQueueController.current(model).itemIds, [Gate1AppModel.welcomeSampleItemId])
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
    // Next in queue on the playback screen's chapter row (#3914).

    /// A third real Library item, so the queue head after B is an item that can start (the race below needs that).
    private func addThirdItem(_ model: Gate1AppModel) throws -> String {
        let store = try model.requireStore()
        try store.saveItem(Item(id: "item-third", title: "Third", mediaType: "text", text: "One.\n\nTwo.", externalReference: nil, status: "Ready"))
        try model.refreshLibraryRows(store: store)
        return "item-third"
    }

    /// A is playing with B then C queued. The tap starts B once, B leaves the queue, and A keeps its place: it is neither
    /// finished nor put back on the queue.
    func testNextInQueueStartsTheQueuedItemOnceAndLeavesTheOneLeftUnfinished() throws {
        let model = makeModel()
        model.addSampleItem()
        let third = try addThirdItem(model)
        let second = Gate1AppModel.welcomeSampleItemId
        model.startItem(id: "item-pill")
        model.queueAppend(itemId: second)
        model.queueAppend(itemId: third)
        XCTAssertEqual(model.chapterRowQueuedNextId, second)

        model.playNextQueuedItem(expectedId: second)

        XCTAssertEqual(model.snapshot.itemId, second)
        XCTAssertEqual(PlayQueueController.current(model).itemIds, [third])
        XCTAssertFalse(PlayQueueController.current(model).contains("item-pill"), "the skipped item is not queued again")
        let left = try model.requireStore().loadSessions(itemId: "item-pill")
        XCTAssertFalse(left.isEmpty)
        XCTAssertTrue(left.allSatisfy { $0.phase != .finished && $0.completedAt == nil }, "the skipped item is not marked finished")
    }

    /// Two taps drawn for the same item start it once and pop the queue once: after the first, the head is the next one.
    func testASecondTapOnNextInQueueDoesNothing() throws {
        let model = makeModel()
        model.addSampleItem()
        let third = try addThirdItem(model)
        let second = Gate1AppModel.welcomeSampleItemId
        model.startItem(id: "item-pill")
        model.queueAppend(itemId: second)
        model.queueAppend(itemId: third)
        model.playNextQueuedItem(expectedId: second)
        let session = model.snapshot.sessionId
        model.playNextQueuedItem(expectedId: second)
        XCTAssertEqual(model.snapshot.itemId, second)
        XCTAssertEqual(model.snapshot.sessionId, session, "no second session was started")
        XCTAssertEqual(PlayQueueController.current(model).itemIds, [third], "the queue was popped once")
    }

    /// A tap in the moment the queue advances by itself. The advance has already taken B off the queue and starts it a
    /// moment later; C is the new head and a real item. The button must not be offered for C then, and a tap drawn for
    /// C starts nothing: B starts once and C is still queued.
    func testATapAtTheQueuesOwnAdvanceStartsTheNextItemOnceAndLosesNothing() async throws {
        let model = makeModel()
        model.addSampleItem()
        let second = Gate1AppModel.welcomeSampleItemId
        let third = try addThirdItem(model)
        model.startItem(id: "item-pill")
        model.queueAppend(itemId: second)
        model.queueAppend(itemId: third)
        XCTAssertEqual(model.chapterRowQueuedNextId, second)

        var playing = model.snapshot
        playing.phase = .itemPlayback
        model.snapshot = playing
        var finished = playing
        finished.phase = .finished
        model.snapshot = finished // the edge: the advance pops B now and starts it after this change has settled
        XCTAssertEqual(PlayQueueController.current(model).itemIds, [third], "the advance has popped B")
        XCTAssertNil(model.chapterRowQueuedNextId, "the row does not offer C while the advance is pending")
        model.playNextQueuedItem(expectedId: third)
        await Task.yield()

        XCTAssertEqual(model.snapshot.itemId, second)
        XCTAssertEqual(PlayQueueController.current(model).itemIds, [third], "C was not started and not lost")
        XCTAssertEqual(try model.requireStore().loadSessions(itemId: third).count, 0)
    }

    /// The tap is an explicit start, so it cancels a running sleep timer as starting a queued item from the queue screen does.
    func testNextInQueueCancelsARunningSleepTimer() {
        let model = makeModel()
        model.addSampleItem()
        model.startItem(id: "item-pill")
        model.queueAppend(itemId: Gate1AppModel.welcomeSampleItemId)
        model.armSleepTimer(.minutes15)
        defer { model.cancelSleepTimer() }
        model.playNextQueuedItem(expectedId: Gate1AppModel.welcomeSampleItemId)
        XCTAssertFalse(model.sleepTimerIsActive)
        XCTAssertEqual(model.snapshot.itemId, Gate1AppModel.welcomeSampleItemId)
    }

    /// With nothing queued, or only the playing item at the head, there is nothing to offer and a stale tap does nothing.
    func testNextInQueueIsNotOfferedWithAnEmptyQueueOrOnlyThePlayingItem() {
        let model = makeModel()
        model.startItem(id: "item-pill")
        XCTAssertNil(model.chapterRowQueuedNextId)
        model.queueAppend(itemId: "item-pill")
        XCTAssertNil(model.chapterRowQueuedNextId, "the head is the item already playing")
    }
}
