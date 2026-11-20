import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #3769: a folder or a titled link list picked in Files becomes a collection, quietly. Real temporary files and a real
/// store; links resolve through a per-address resolver, so no network is touched.
@MainActor
final class CollectionImportAppTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "collection-import-\(UUID().uuidString)")
        directories.append(root)
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeModel(resolver: LinkResolutionClient? = nil) throws -> Gate1AppModel {
        let root = try makeDirectory("db")
        let model = Gate1AppModel(sourceLinkResolver: resolver, audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed(); model.declineCurrentTerms()
        return model
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func titles(_ collection: ItemCollection?, in model: Gate1AppModel) -> [String] {
        (collection?.itemIDs ?? []).compactMap { id in model.libraryItems.first { $0.id == id }?.title }
    }

    func testAFolderBecomesACollectionInFileOrderWithOneLineAndNoBannerPerFile() async throws {
        let model = try makeModel()
        let screen = model.screen
        let folder = try makeDirectory("Reading group")
        try write("# Chapter ten\nTen.", to: folder.appending(path: "chapter 10.md"))
        try write("# Chapter two\nTwo.", to: folder.appending(path: "chapter 2.md"))
        try write("Notes for week one.", to: folder.appending(path: "week/notes.txt"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appending(path: "cover.png"))

        let summary = await model.importFolderAsCollection(folder)

        XCTAssertEqual(summary?.message, "Made “Reading group” with 3 items.")
        XCTAssertEqual(model.feedbackEvent?.message, "Made “Reading group” with 3 items.", "the one line, not a banner per file")
        let collection = model.libraryCollections.collections.first { $0.name == "Reading group" }
        XCTAssertEqual(titles(collection, in: model), ["Chapter two", "Chapter ten", "notes"], "natural file order, subfolders after")
        let record = try XCTUnwrap(model.libraryCollections.folders.first { $0.id == collection?.id })
        XCTAssertEqual(record.members.map(\.state), [.added, .added, .added])
        XCTAssertEqual(record.skippedOtherCount, 1, "the picture is counted, not added")
        XCTAssertNil(model.libraryCollections.importCapture)
        XCTAssertEqual(model.screen, screen, "a folder opens nothing")

        // Picking the same folder again adds only the new file, in its place.
        try write("# Chapter five\nFive.", to: folder.appending(path: "chapter 5.md"))
        let again = await model.importFolderAsCollection(folder)
        XCTAssertEqual(again?.message, "Added 1 item to “Reading group”.")
        let updated = model.libraryCollections.collections.first { $0.id == collection?.id }
        XCTAssertEqual(titles(updated, in: model), ["Chapter two", "Chapter five", "Chapter ten", "notes"])
        XCTAssertEqual(model.libraryCollections.collections.filter { $0.name.hasPrefix("Reading group") }.count, 1)

        let unchanged = await model.importFolderAsCollection(folder)
        XCTAssertEqual(unchanged?.message, "“Reading group” is up to date.")
    }

    func testAFolderWithNothingToAddMakesNoCollection() async throws {
        let model = try makeModel()
        let folder = try makeDirectory("Pictures")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appending(path: "a.png"))
        let summary = await model.importFolderAsCollection(folder)
        XCTAssertEqual(summary?.kind, .failure)
        XCTAssertEqual(summary?.message, "There's nothing in “Pictures” the app can add.")
        XCTAssertEqual(model.feedbackEvent?.message, summary?.message, "shown, not held by the import's own capture")
        XCTAssertFalse(model.libraryCollections.collections.contains { $0.name == "Pictures" })
        XCTAssertNil(model.libraryCollections.importCapture)
    }

    /// A pick while another import runs is turned away with a line the listener sees. The running import's capture must
    /// not swallow it, nor take it as the reason its current file failed (#3769 audit).
    func testTheBusyLineIsShownAndNotHeldByTheRunningImport() async throws {
        let model = try makeModel()
        let running = CollectionImportCapture()
        model.libraryCollections.importCapture = running // an import is mid-way through a file
        let second = await model.importFolderAsCollection(try makeDirectory("Second"))
        XCTAssertNil(second)
        XCTAssertEqual(model.feedbackEvent?.message, Gate1AppModel.collectionImportBusyMessage)
        XCTAssertTrue(model.libraryCollections.importCapture === running, "the running import keeps its capture")
        XCTAssertNil(running.take().problem, "not recorded as the running file's failure")
    }

    func testATitledLinkListBecomesACollectionInListOrderAndABadLinkIsCounted() async throws {
        let model = try makeModel(resolver: PerAddressResolver(playable: [
            "https://example.com/one": "https://audio.example/one.mp3",
            "https://example.com/two": "https://audio.example/two.mp3",
        ]))
        let folder = try makeDirectory("lists")
        let url = folder.appending(path: "week.json")
        let list = LinkListFile(title: "Week 3 listening", entries: [
            .init(url: "https://example.com/two", title: "Two"),
            .init(url: "https://example.com/broken", title: "Broken"),
            .init(url: "https://example.com/one", title: "One"),
        ])

        let summary = await model.importLinkListAsCollection(url, list: list, title: "Week 3 listening")

        XCTAssertEqual(summary?.message, "Made “Week 3 listening” with 2 items. 1 couldn't be added.")
        XCTAssertEqual(summary?.kind, .warning)
        XCTAssertEqual(model.feedbackEvent?.message, summary?.message)
        let collection = try XCTUnwrap(model.libraryCollections.collections.first { $0.name == "Week 3 listening" })
        XCTAssertEqual(collection.itemIDs.count, 2)
        let record = try XCTUnwrap(model.libraryCollections.folders.first { $0.id == collection.id })
        XCTAssertEqual(record.members.map(\.address), ["https://example.com/two", "https://example.com/broken", "https://example.com/one"])
        XCTAssertEqual(record.members.map(\.state), [.added, .failed, .added])
        XCTAssertEqual(collection.itemIDs, [record.members[0].itemID, record.members[2].itemID].compactMap { $0 }, "list order")
        XCTAssertNotNil(record.members[1].reason)
    }

    func testAnImportEndedMidWayIsSettledAtTheNextLaunch() async throws {
        let root = try makeDirectory("db")
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed(); model.declineCurrentTerms()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let existing = try XCTUnwrap(model.libraryItems.first?.id)
        let now = Date()
        // Saved as the importer leaves them: one item landed but missed the collection, one never got saved.
        try store.saveItemCollection(ItemCollection(id: "collection-x", name: "Interrupted", createdAt: now))
        try store.saveLibraryFolder(LibraryFolderRecord(id: "collection-x", sourcePath: "/picked/Interrupted", importedAt: now, members: [
            .init(key: "a.md", kind: .markdown, name: "a.md", itemID: existing, addedAt: now),
            .init(key: "b.md", kind: .markdown, name: "b.md", itemID: "item-never-saved", addedAt: now),
        ]))
        try store.saveLibraryFolder(LibraryFolderRecord(id: "collection-gone", sourcePath: "/picked/Gone", importedAt: now))

        let relaunched = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        relaunched.bootstrapLibraryIfNeeded()

        let folders = try store.loadLibraryFolders()
        XCTAssertEqual(folders.map(\.id), ["collection-x"], "the orphan record went; no item was touched")
        XCTAssertEqual(folders.first?.members.map(\.state), [.added, .failed])
        XCTAssertEqual(folders.first?.members.last?.reason, LibraryFolderRecord.stoppedReason)
        XCTAssertEqual(try store.loadItemCollections().first { $0.id == "collection-x" }?.itemIDs, [existing])
    }

    // MARK: Edits while an import runs (#3769 audit)

    /// The import writes each file into the collection as stored, and a rename or edit made from an older copy keeps
    /// what the import added since: neither side writes back a stale snapshot.
    func testARenameFromAnOlderCopyKeepsWhatTheImportAddedSince() async throws {
        let model = try makeModel()
        let store = try model.requireStore()
        let folder = try makeDirectory("Week")
        try write("# One\nOne.", to: folder.appending(path: "1.md"))
        try write("# Two\nTwo.", to: folder.appending(path: "2.md"))
        _ = await model.importFolderAsCollection(folder)
        let older = try XCTUnwrap(model.libraryCollections.collections.first { $0.name == "Week" })
        let extra = try XCTUnwrap(model.libraryItems.first { !older.itemIDs.contains($0.id) }?.id)

        // What an import's next file does: it joins the stored collection.
        let added = await model.libraryCollections.update(older.id, store: store) { current, _ in
            var next = current; next.itemIDs.append(extra); return next
        }
        guard case .saved = added else { return XCTFail("the import's write should save, got \(added)") }
        // The row the listener renames was drawn before that file landed.
        let renamed = await model.libraryCollections.rename(older, to: "Week three", store: store)
        guard case .saved = renamed else { return XCTFail("rename should save, got \(renamed)") }

        let stored = try XCTUnwrap(try store.loadItemCollections().first { $0.id == older.id })
        XCTAssertEqual(stored.name, "Week three")
        XCTAssertEqual(stored.itemIDs, older.itemIDs + [extra], "the rename kept the item the import added")

        // And an edit from the older copy that leaves `extra` unticked only because the sheet never showed it.
        let edited = await model.libraryCollections.setItems(
            Set(older.itemIDs.dropLast()), in: older, choosable: older.itemIDs, store: store)
        guard case .saved = edited else { return XCTFail("edit should save, got \(edited)") }
        let afterEdit = try XCTUnwrap(try store.loadItemCollections().first { $0.id == older.id })
        XCTAssertTrue(afterEdit.itemIDs.contains(extra), "an item the sheet couldn't choose stays")
        XCTAssertEqual(afterEdit.name, "Week three")
    }

    /// The Add to Collection sheet's tick and rename land on the stored copy (#3769 audit): the sheet drew the row before
    /// the import's next file joined it, and neither change drops that file.
    func testATickOrRenameFromTheSheetsOlderCopyKeepsWhatTheImportAddedSince() async throws {
        let model = try makeModel()
        let store = try model.requireStore()
        let folder = try makeDirectory("Week")
        try write("# One\nOne.", to: folder.appending(path: "1.md"))
        _ = await model.importFolderAsCollection(folder)
        // Two more Library items outside "Week", from another folder.
        let other = try makeDirectory("Other")
        try write("# Two\nTwo.", to: other.appending(path: "2.md"))
        try write("# Three\nThree.", to: other.appending(path: "3.md"))
        _ = await model.importFolderAsCollection(other)
        let drawn = try XCTUnwrap(model.libraryCollections.collections.first { $0.name == "Week" })
        let outside = model.libraryItems.filter { !drawn.itemIDs.contains($0.id) }.map(\.id)
        guard outside.count >= 2 else { return XCTFail("need two items outside the collection, have \(outside.count)") }
        let fromImport = outside[0], ticked = outside[1]

        let added = await model.libraryCollections.update(drawn.id, store: store) { current, _ in
            var next = current; next.itemIDs.append(fromImport); return next
        }
        guard case .saved = added else { return XCTFail("the import's write should save, got \(added)") }

        let tick = await model.libraryCollections.setMembership(of: ticked, included: true, in: drawn, store: store)
        guard case .saved = tick else { return XCTFail("tick should save, got \(tick)") }
        var stored = try XCTUnwrap(try store.loadItemCollections().first { $0.id == drawn.id })
        XCTAssertEqual(stored.itemIDs, drawn.itemIDs + [fromImport, ticked], "the tick kept the import's item")

        // A tick on a row that showed no checkmark, for an item that joined since, leaves it in.
        _ = await model.libraryCollections.setMembership(of: fromImport, included: true, in: drawn, store: store)
        stored = try XCTUnwrap(try store.loadItemCollections().first { $0.id == drawn.id })
        XCTAssertTrue(stored.itemIDs.contains(fromImport))

        let renamed = await model.libraryCollections.rename(drawn, to: "Week two", store: store)
        guard case .saved = renamed else { return XCTFail("rename should save, got \(renamed)") }
        stored = try XCTUnwrap(try store.loadItemCollections().first { $0.id == drawn.id })
        XCTAssertEqual(stored.name, "Week two")
        XCTAssertEqual(stored.itemIDs, drawn.itemIDs + [fromImport, ticked])
    }

    /// A collection deleted while its import is filling it stays deleted: the next file's write finds it gone.
    func testACollectionDeletedDuringAnImportIsNotSavedBack() async throws {
        let model = try makeModel()
        let store = try model.requireStore()
        let folder = try makeDirectory("Gone soon")
        try write("# One\nOne.", to: folder.appending(path: "1.md"))
        _ = await model.importFolderAsCollection(folder)
        let collection = try XCTUnwrap(model.libraryCollections.collections.first { $0.name == "Gone soon" })
        let record = try XCTUnwrap(model.libraryCollections.folders.first { $0.id == collection.id })

        _ = await model.libraryCollections.delete(collection, store: store)
        let late = await model.libraryCollections.update(collection.id, record: record, store: store) { current, _ in current }

        guard case .gone = late else { return XCTFail("a write after the delete should find it gone, got \(late)") }
        XCTAssertFalse(try store.loadItemCollections().contains { $0.id == collection.id }, "not brought back")
        XCTAssertFalse(model.libraryCollections.collections.contains { $0.id == collection.id })
    }

    /// The busy guard holds from the moment a pick starts, before the folder walk's first await.
    func testASecondPickDuringTheWalkIsTurnedAway() async throws {
        let model = try makeModel()
        let folder = try makeDirectory("First")
        try write("# One\nOne.", to: folder.appending(path: "1.md"))
        let first = Task { await model.importFolderAsCollection(folder) }
        await Task.yield()
        // The first pick has run up to its walk's await; a second pick now must not start.
        XCTAssertNotNil(model.libraryCollections.importCapture, "busy before the walk's await")
        let second = await model.importFolderAsCollection(try makeDirectory("Second"))
        XCTAssertNil(second)
        XCTAssertEqual(model.feedbackEvent?.message, Gate1AppModel.collectionImportBusyMessage)
        _ = await first.value
        XCTAssertNil(model.libraryCollections.importCapture, "cleared when the import ends")
    }
}

/// Playable for the addresses it knows; anything else fails the way an unreachable page does.
private struct PerAddressResolver: LinkResolutionClient {
    var playable: [String: String]

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        guard let audioURL = playable[request.inputURL] else { throw URLError(.cannotFindHost) }
        return LinkResolutionResult(
            requestId: request.id, status: .playable,
            originalLink: SourceLink(url: request.inputURL, role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: audioURL, role: "media"), title: audioURL, durationMs: 300_000,
                audioURL: audioURL, confidence: 1))
    }
}
