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

    private let otterTXT = """
    Budget sync
    Mar 4, 2026 10:00 AM

    Alice Example  0:03
    Welcome everyone, let's start with the budget.

    Ben Sample  0:06
    Thanks. I have the draft numbers ready.

    Alice Example  0:09
    Great, please share them.
    """

    private let essayTXT = "A short essay.\n\nIt has two paragraphs and no meeting in it."

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

    private func quickFile(_ url: URL) -> QuickAccessFile {
        QuickAccessFile(
            id: "quick-\(url.lastPathComponent)", name: url.lastPathComponent, relativePath: url.lastPathComponent,
            modifiedAt: Date(timeIntervalSince1970: 1_000), modifiedAtDescription: "")
    }

    /// The model's Quick Folder remembers dismissed files in the standard defaults; put them back after the test.
    private func restoreDismissedQuickFilesAfterTheTest() {
        let key = "dismissedQuickAccessFilesV1"
        let prior = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Runs a pick and returns what the route heard and how many times it heard it. The count is read after a pause, so
    /// a second call to `onFinished` shows up.
    private func importPick(
        _ urls: [URL], route: Gate1AppModel.TranscriptPickRoute, on model: Gate1AppModel
    ) async throws -> (outcome: Gate1AppModel.TranscriptPickOutcome, calls: Int) {
        let finished = expectation(description: "the pick ended")
        finished.assertForOverFulfill = true
        var heard: Gate1AppModel.TranscriptPickOutcome?
        var calls = 0
        var route = route
        let original = route.onFinished
        route.onFinished = { outcome in
            calls += 1
            heard = outcome
            original?(outcome)
            if calls == 1 { finished.fulfill() }
        }
        model.importFilesWithTranscriptRule(urls: urls, route: route)
        await fulfillment(of: [finished], timeout: 20)
        try await Task.sleep(nanoseconds: 200_000_000)
        return (heard ?? .nothing, calls)
    }

    private func kinds(of ids: [String], in store: SQLiteSessionStore) throws -> [String?] {
        try ids.map { try store.loadItem(id: $0).externalReferenceType }
    }

    func testAPickWithATranscriptHearsEveryItemOnceInTheOrderPicked() async throws {
        let (model, store) = try makeModel()
        let urls = try writeFiles([
            (name: "essay.txt", text: essayTXT), (name: "meeting.txt", text: otterTXT), (name: "notes.md", text: "# Notes\n\nSomething to read."),
        ])
        let result = try await importPick(urls, route: .init(securityScopedURLs: []), on: model)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.outcome.itemIds.count, 3)
        XCTAssertEqual(try kinds(of: result.outcome.itemIds, in: store), ["file", TranscriptItemText.referenceType, "file"],
                       "a Zoom-style .txt becomes a transcript, sitting where its file was picked")
    }

    func testAPickWithNoTranscriptKeepsTodaysImportAndHearsItsItemsOnce() async throws {
        let (model, store) = try makeModel()
        let urls = try writeFiles([(name: "essay.txt", text: essayTXT), (name: "notes.md", text: "# Notes\n\nSomething to read.")])
        let result = try await importPick(urls, route: .init(securityScopedURLs: []), on: model)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(try kinds(of: result.outcome.itemIds, in: store), ["file", "file"])
    }

    func testAPickThatCannotStartHearsAnEndOnceWhateverTheFilesAre() async throws {
        let (model, _) = try makeModel()
        let busy = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        model.sourceImportTask = busy
        defer { busy.cancel(); model.sourceImportTask = nil }
        for name in ["meeting.txt", "notes.md"] {
            let urls = try writeFiles([(name: name, text: name.hasSuffix(".md") ? "# Notes" : otterTXT)])
            let result = try await importPick(urls, route: .init(securityScopedURLs: []), on: model)
            XCTAssertEqual(result.calls, 1, name)
            XCTAssertEqual(result.outcome.itemIds, [], name)
        }
        let none = try await importPick([], route: .init(securityScopedURLs: []), on: model)
        XCTAssertEqual(none.calls, 1)
    }

    func testAZoomTxtSwipedToTheQueueIsSavedAsATranscriptAndQueued() async throws {
        restoreDismissedQuickFilesAfterTheTest()
        let (model, store) = try makeModel()
        let url = try writeFiles([(name: "meeting.txt", text: otterTXT)])[0]
        let file = quickFile(url)
        QueueWishController.register(file.id)
        let result = try await importPick([url], route: model.quickFolderSwipeRoute(for: file, folderURL: url.deletingLastPathComponent()), on: model)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(queuedIds, result.outcome.itemIds, "the wish was settled with the saved transcript, once")
        XCTAssertEqual(queuedIds.count, 1)
        XCTAssertEqual(try kinds(of: queuedIds, in: store), [TranscriptItemText.referenceType])
    }

    func testAnEssayTxtSwipedToTheQueueStillImportsAsTextAndIsQueued() async throws {
        restoreDismissedQuickFilesAfterTheTest()
        let (model, store) = try makeModel()
        let url = try writeFiles([(name: "essay.txt", text: essayTXT)])[0]
        let file = quickFile(url)
        QueueWishController.register(file.id)
        let result = try await importPick([url], route: model.quickFolderSwipeRoute(for: file, folderURL: url.deletingLastPathComponent()), on: model)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(try kinds(of: queuedIds, in: store), ["file"])
    }

    /// The model's Quick Folder reads the standard defaults: put its keys back after the test.
    private func restoreQuickFolderDefaultsAfterTheTest() {
        let keys = [
            "quickAccessFolderBookmark", "quickAccessFolderName", "quickAccessFolderPath", "quickAccessLastCheckedAt",
            "quickAccessFolderProblem", "quickAccessFolderChosenAt", "dismissedQuickAccessFilesV1",
            QuickFolderListStore.listKey, QuickFolderListStore.retiredDismissalsKey,
        ] + QuickAccessFolderState.retiredKeys
        let prior = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock {
            for (key, value) in prior {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    /// #4274: new Quick Folder files only wait on Following. A refresh that finds them (at launch, on pull to refresh, or
    /// here) never imports them, never touches the queue or the loaded item, and says nothing; the listener's own Add to
    /// Queue still queues one. Seeded with the retired switch on, so on the code before #4274 the inbox imports and queues
    /// the three files the moment the refresh ends, and the queue and Library assertions fail.
    func testNewQuickFolderFilesNeverChangeThePlayQueue() async throws {
        restoreQuickFolderDefaultsAfterTheTest()
        UserDefaults.standard.set(true, forKey: "quickFolderFeedsQueueV1")
        let priorQueue = queuedIds
        let (model, _) = try makeModel()
        addTeardownBlock { @MainActor in
            PlayQueueController.update(model) { queue in
                queue.clear()
                priorQueue.forEach { queue.append($0) }
            }
        }
        XCTAssertNil(UserDefaults.standard.object(forKey: "quickFolderFeedsQueueV1"), "the retired switch is deleted at launch")
        let loadedItem = model.activeItemId
        PlayQueueController.update(model) { queue in ["swipe-a", "swipe-b"].forEach { queue.append($0) } }
        XCTAssertEqual(queuedIds, ["swipe-a", "swipe-b"])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-folder-no-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        model.configureQuickAccessFolder(url: folder)
        try await pollUntil { model.quickAccess.lastCheckedAt != nil && !model.quickAccess.isRefreshing }
        XCTAssertNotNil(model.quickAccess.lastCheckedAt, "the first scan of the empty folder finished")

        try "# Notes\n\nSomething to read.".write(to: folder.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        try otterTXT.write(to: folder.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try #"{"schemaVersion":"spoken-margins.link-list.v1","entries":[{"url":"https://example.com/a"}]}"#
            .write(to: folder.appendingPathComponent("three.json"), atomically: true, encoding: .utf8)
        let libraryCount = model.libraryItems.count

        func folderFiles() -> [QuickAccessFile] {
            model.quickAddCandidates.compactMap { if case .localFile(let file) = $0 { file } else { nil } }
        }
        model.refreshQuickAccessFolder()
        try await pollUntil { !model.quickAccess.isRefreshing && folderFiles().count == 3 }
        // No wait for "nothing happened": the old inbox started its import in the same main-actor turn the refresh ended
        // (`finishRefresh` called it directly), so on that code `sourceImportTask` is already set when the poll above returns.

        XCTAssertEqual(folderFiles().count, 3, "all three new files wait on Following")
        XCTAssertEqual(queuedIds, ["swipe-a", "swipe-b"], "the queue is untouched")
        XCTAssertEqual(model.libraryItems.count, libraryCount, "nothing was imported")
        XCTAssertNil(model.sourceImportTask, "no import started")
        XCTAssertFalse(model.statusMessage.hasPrefix("Queued"), model.statusMessage)
        XCTAssertFalse(model.feedbackEvent?.message.hasPrefix("Queued") ?? false)
        XCTAssertEqual(model.activeItemId, loadedItem, "the loaded item is untouched")

        // The listener's own Add to Queue still queues the file. A row's `name` drops the extension (`QuickAccessFolderScanner`);
        // the file name is its `id`.
        let one = try XCTUnwrap(folderFiles().first { $0.id == "one.md" })
        model.addQuickFolderFileToQueue(one)
        try await pollUntil { queuedIds.count == 3 }
        XCTAssertEqual(queuedIds.count, 3)
        XCTAssertEqual(Array(queuedIds.prefix(2)), ["swipe-a", "swipe-b"])
        XCTAssertEqual(model.libraryItems.count, libraryCount + 1)
        if let added = queuedIds.last {
            XCTAssertTrue(model.libraryItems.contains { $0.id == added }, "the queued id is the item one.md saved")
        }
    }
}
