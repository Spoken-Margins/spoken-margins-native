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

    // MARK: The Quick Folder's queue paths and meeting transcripts (#2997)

    private let meetingSRT = """
    1
    00:00:03,500 --> 00:00:06,000
    Alice Example: Welcome everyone, let's start with the budget.

    2
    00:00:06,500 --> 00:00:09,000
    Ben Sample: Thanks. I have the draft numbers ready.

    3
    00:00:09,500 --> 00:00:12,000
    Alice Example: Great, please share them.
    """

    private func writeFiles(_ files: [(name: String, text: String)]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("queue-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try files.map { file in
            let url = folder.appendingPathComponent(file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    private func importPick(_ urls: [URL], on model: Gate1AppModel) async -> Gate1AppModel.TranscriptPickOutcome {
        let finished = expectation(description: "the pick ended")
        var heard: Gate1AppModel.TranscriptPickOutcome?
        model.importFilesWithTranscriptRule(
            urls: urls,
            route: .init(securityScopedURLs: [], onFinished: { outcome in
                heard = outcome
                finished.fulfill()
            }))
        await fulfillment(of: [finished], timeout: 20)
        return heard ?? .nothing
    }

    func testAPickWithATranscriptHearsEveryItemInTheOrderPicked() async throws {
        let (model, store) = try makeModel()
        let urls = try writeFiles([
            (name: "essay.txt", text: "A short essay.\n\nIt has two paragraphs and no meeting in it."),
            (name: "budget.srt", text: meetingSRT),
            (name: "notes.md", text: "# Notes\n\nSomething to read."),
        ])
        let outcome = await importPick(urls, on: model)
        XCTAssertTrue(outcome.handledTranscript)
        XCTAssertEqual(outcome.itemIds.count, 3)
        let kinds = try outcome.itemIds.map { try store.loadItem(id: $0).externalReferenceType }
        XCTAssertEqual(kinds, ["file", TranscriptItemText.referenceType, "file"], "the transcript sits where its file was picked")
    }

    func testAPickWithNoTranscriptKeepsTodaysImportAndHearsItsItems() async throws {
        let (model, store) = try makeModel()
        let urls = try writeFiles([
            (name: "essay.txt", text: "A short essay.\n\nIt has two paragraphs and no meeting in it."),
            (name: "notes.md", text: "# Notes\n\nSomething to read."),
        ])
        let outcome = await importPick(urls, on: model)
        XCTAssertFalse(outcome.handledTranscript)
        XCTAssertEqual(outcome.itemIds.count, 2)
        XCTAssertEqual(try outcome.itemIds.map { try store.loadItem(id: $0).externalReferenceType }, ["file", "file"])
    }

    func testAZoomTranscriptSwipedToTheQueueIsQueuedAsATranscript() async throws {
        let (model, store) = try makeModel()
        let urls = try writeFiles([(name: "budget.srt", text: meetingSRT)])
        QueueWishController.register("entry-transcript")
        let outcome = await importPick(urls, on: model)
        model.settleQueueWish(key: "entry-transcript", itemId: outcome.itemIds.first)
        let queued = try XCTUnwrap(queuedIds.first)
        XCTAssertEqual(queuedIds.count, 1)
        XCTAssertEqual(try store.loadItem(id: queued).externalReferenceType, TranscriptItemText.referenceType)
    }

    func testAPickThatCannotStartHearsNothingSoAQueueWishIsReleasedAsFailed() async throws {
        let (model, _) = try makeModel()
        let urls = try writeFiles([(name: "budget.srt", text: meetingSRT)])
        let busy = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        model.sourceImportTask = busy
        defer { busy.cancel(); model.sourceImportTask = nil }
        QueueWishController.register("entry-busy")
        let outcome = await importPick(urls, on: model)
        XCTAssertEqual(outcome.itemIds, [])
        model.settleQueueWish(key: "entry-busy", itemId: outcome.itemIds.first)
        XCTAssertEqual(queuedIds, [])
    }
}
