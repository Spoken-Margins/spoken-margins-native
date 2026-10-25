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
}
