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
        XCTAssertFalse(model.libraryCollections.collections.contains { $0.name == "Pictures" })
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
