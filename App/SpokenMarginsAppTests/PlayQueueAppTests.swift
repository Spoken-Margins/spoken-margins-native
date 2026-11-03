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
