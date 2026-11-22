import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #4227: permanent delete also takes off the files the app copied in from Files (an EPUB, an audiobook) and the item's
/// episode-map folder, through the same journal as the narration chunks. Real temporary files and a real SQLite store;
/// the only fake is the one removal call, in the failure test.
final class PermanentDeleteCopiedSourcesTests: XCTestCase {
    private var support: URL!
    private let manager = FileManager.default
    private var journal: URL { support.appending(path: "SpokenMargins/PurgeJournal", directoryHint: .isDirectory) }
    private var sources: URL { support.appending(path: "SourceDocuments", directoryHint: .isDirectory) }
    private var audiobooks: URL { support.appending(path: "Audiobooks", directoryHint: .isDirectory) }
    private var prepared: URL { support.appending(path: "PreparedAudio", directoryHint: .isDirectory) }
    private var editions: URL { support.appending(path: "SpokenMargins/ListeningEditions", directoryHint: .isDirectory) }
    private var maps: URL { support.appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory) }
    private var clips: URL { support.appending(path: "SpokenMargins/PDFClips", directoryHint: .isDirectory) }

    private let epub = "epub-6f1c2d3e-0000-4000-8000-000000000001"
    private let book = "audiobook-6f1c2d3e-0000-4000-8000-000000000002"
    private let other = "epub-6f1c2d3e-0000-4000-8000-000000000003"

    override func setUpWithError() throws {
        support = manager.temporaryDirectory.appending(path: "copied-\(UUID().uuidString)", directoryHint: .isDirectory)
        for directory in [sources, audiobooks, maps] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try? manager.removeItem(at: support) }

    private func purge(removeFile: (@Sendable (URL) throws -> Void)? = nil) -> PermanentDeletePurge {
        let roots = [
            PermanentDeletePurge.Root(name: ItemOwnedFiles.sourceDocumentsRoot, url: sources),
            PermanentDeletePurge.Root(name: ItemOwnedFiles.audiobooksRoot, url: audiobooks),
            PermanentDeletePurge.Root(name: ItemOwnedFiles.episodeMapsRoot, url: maps),
            PermanentDeletePurge.Root(name: ItemOwnedFiles.pdfClipsRoot, url: clips),
            PermanentDeletePurge.Root(name: ItemOwnedFiles.preparedAudioRoot, url: prepared),
            PermanentDeletePurge.Root(name: ItemOwnedFiles.listeningEditionsRoot, url: editions),
            // Every item's targets name its kept original (#4338), so the app, and a test that stands for it, registers the root.
            PermanentDeletePurge.Root(name: ItemOwnedFiles.itemOriginalsRoot, url: support.appending(path: "ItemOriginals", directoryHint: .isDirectory)),
        ]
        if let removeFile { return PermanentDeletePurge(journalDirectory: journal, roots: roots, removeFile: removeFile) }
        return PermanentDeletePurge(journalDirectory: journal, roots: roots)
    }

    private func asset(
        _ category: OfflineAssetCategory, item: String?, path: String, id: String = UUID().uuidString
    ) -> OwnedOfflineAsset {
        OwnedOfflineAsset(id: id, itemId: item, category: category, relativePath: path, byteCount: 4, isReproducible: false)
    }

    private func epubAsset(_ id: String) -> OwnedOfflineAsset {
        asset(.sourceDocument, item: id, path: "SourceDocuments/\(id).epub", id: "source-asset-\(id)")
    }

    private func audiobookAsset(_ id: String, ext: String = "m4b") -> OwnedOfflineAsset {
        asset(.audiobook, item: id, path: "Audiobooks/\(id).\(ext)", id: "audiobook-owned-\(id)")
    }

    private func write(_ url: URL, _ text: String = "data") throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }

    private func store() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: support.appending(path: "store.sqlite").path)
    }

    private func save(_ id: String, in store: SQLiteSessionStore) throws {
        try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
    }

    // MARK: Which rows name a file the item owns

    /// A table of rows, each with the answer the writer's own layout gives.
    func testWhichLedgerRowsNameACopiedSourceFile() {
        let table: [(asset: OwnedOfflineAsset, item: String, kept: Bool, note: String)] = [
            (epubAsset(epub), epub, true, "the EPUB the importer writes"),
            (audiobookAsset(book, ext: "m4b"), book, true, "an m4b"),
            (audiobookAsset(book, ext: "mp3"), book, true, "an mp3"),
            (audiobookAsset(book, ext: "m4a"), book, true, "an m4a"),
            (audiobookAsset(book, ext: "mp4"), book, true, "an mp4"),
            (audiobookAsset(book, ext: "wav"), book, false, "a type the importer never writes"),
            (audiobookAsset(book, ext: "M4B"), book, false, "the importer lower-cases the extension"),
            (epubAsset(epub), other, false, "another item's row"),
            (asset(.sourceDocument, item: nil, path: "SourceDocuments/\(epub).epub"), epub, false, "a row with no item"),
            (asset(.sourceDocument, item: epub, path: "SourceDocuments/\(epub).epub.bak"), epub, false, "a longer extension"),
            (asset(.sourceDocument, item: epub, path: "SourceDocuments/\(epub)"), epub, false, "no extension"),
            (asset(.sourceDocument, item: epub, path: "SourceDocuments/\(epub).m4b"), epub, false, "an audio file on a document row"),
            (asset(.audiobook, item: book, path: "Audiobooks/\(book).epub"), book, false, "a document file on an audiobook row"),
            (asset(.sourceDocument, item: epub, path: "SourceDocuments/\(other).epub"), epub, false, "another item's file"),
            (asset(.sourceDocument, item: epub, path: "SourceDocuments/sub/\(epub).epub"), epub, false, "a nested path"),
            (asset(.sourceDocument, item: epub, path: "SourceDocuments/../SpokenMargins/\(epub).epub"), epub, false, "a path that climbs"),
            (asset(.sourceDocument, item: epub, path: "/SourceDocuments/\(epub).epub"), epub, false, "an absolute path"),
            (asset(.sourceDocument, item: epub, path: "Audiobooks/\(epub).epub"), epub, false, "the wrong folder for the category"),
            (asset(.sourceDocument, item: epub, path: "SpokenMargins/library.sqlite"), epub, false, "the database is never named"),
            (asset(.preparedAudio, item: epub, path: "SourceDocuments/\(epub).epub"), epub, false, "another category"),
            (asset(.interjection, item: epub, path: "SourceDocuments/\(epub).epub"), epub, false, "a Margin recording has its own rule"),
            (asset(.sourceDocument, item: "", path: "SourceDocuments/.epub"), "", false, "an empty id"),
        ]
        for row in table {
            let target = ItemOwnedFiles.copiedSourceTarget(forAsset: row.asset, ofItem: row.item)
            XCTAssertEqual(target != nil, row.kept, row.note)
            if let target {
                XCTAssertEqual(target.itemId, row.item, row.note)
                XCTAssertFalse(target.relativePath.contains("/"), "\(row.note): one name under its root")
            }
        }
    }

    func testTheEpisodeMapFolderIsNamedByTheMapsOwnRule() {
        let table: [(id: String, folder: String?, note: String)] = [
            ("item-1", "item-1", "a plain id"),
            ("podcast:abc/1", "podcast-abc-1", "punctuation becomes hyphens"),
            ("a.b", "a.b", "dots are kept by this rule"),
            ("", nil, "empty would name `unknown`"),
            (".", nil, "the folder itself"),
            ("..", nil, "its parent"),
            (String(repeating: "x", count: 120), String(repeating: "x", count: 96), "cut at 96"),
        ]
        for row in table {
            XCTAssertEqual(ItemOwnedFiles.episodeMapDirectoryName(itemId: row.id), row.folder, row.note)
            let target = ItemOwnedFiles.targets(forItem: row.id).first { $0.root == ItemOwnedFiles.episodeMapsRoot }
            XCTAssertEqual(target?.relativePath, row.folder, row.note)
        }
        // The folder the app's own paths use is the folder named.
        XCTAssertEqual(ItemOwnedFiles.episodeMapDirectoryName(itemId: "x y"), PodcastAnchorEvidencePaths.safeComponent("x y"))
    }

    func testItemsDeletedTogetherNameEachSourceFileOnce() {
        let assets = [epubAsset(epub), epubAsset(epub), audiobookAsset(book), epubAsset(other)]
        let targets = ItemOwnedFiles.targets(forItems: [epub, book], assets: assets)
        XCTAssertEqual(
            targets.filter { $0.root == ItemOwnedFiles.sourceDocumentsRoot }.map(\.relativePath), ["\(epub).epub"],
            "the duplicate row names one file, and the item that stays has none")
        XCTAssertEqual(targets.filter { $0.root == ItemOwnedFiles.audiobooksRoot }.map(\.relativePath), ["\(book).m4b"])
    }

    // MARK: A delete removes them

    func testADeleteRemovesTheCopiedFilesAndTheMapFolderAndNoOneElsesAgainstARealStore() async throws {
        let store = try store()
        for id in [epub, book, other] { try save(id, in: store) }
        try store.saveOwnedOfflineAsset(epubAsset(epub))
        try store.saveOwnedOfflineAsset(audiobookAsset(book))
        try store.saveOwnedOfflineAsset(epubAsset(other))
        try write(sources.appending(path: "\(epub).epub")); try write(sources.appending(path: "\(other).epub"))
        try write(audiobooks.appending(path: "\(book).m4b"))
        try write(maps.appending(path: "\(epub)/signature.shazamsignature"))
        try write(maps.appending(path: "\(other)/signature.shazamsignature"))
        try write(clips.appending(path: "\(epub)/float-p1-1.jpg")); try write(clips.appending(path: "\(other)/float-p1-1.jpg"))

        // The rows are read before the delete, as the app does.
        let ids = [epub, book]
        let assets = try ids.flatMap { try store.loadOwnedOfflineAssets(itemId: $0) }
        let purge = purge()
        let outcome = await (try purge.deleting(
            itemIds: ids, targets: ItemOwnedFiles.targets(forItems: ids, assets: assets), recheck: purge.storeRecheck(store: store)
        ) { try store.deleteItems(ids: ids) }).value

        XCTAssertFalse(exists(sources.appending(path: "\(epub).epub")))
        XCTAssertFalse(exists(audiobooks.appending(path: "\(book).m4b")))
        XCTAssertFalse(exists(maps.appending(path: epub)))
        XCTAssertTrue(exists(sources.appending(path: "\(other).epub")), "an item that stays keeps its EPUB")
        XCTAssertTrue(exists(maps.appending(path: other)), "and its map folder")
        XCTAssertFalse(exists(clips.appending(path: epub)), "the deleted item's PDF pictures go")
        XCTAssertTrue(exists(clips.appending(path: "\(other)/float-p1-1.jpg")), "an item that stays keeps its pictures")
        XCTAssertTrue(outcome.kept.isEmpty)
        XCTAssertEqual(outcome.removed.filter { $0.root == ItemOwnedFiles.sourceDocumentsRoot }.count, 1)
        XCTAssertEqual(outcome.removed.filter { $0.root == ItemOwnedFiles.audiobooksRoot }.count, 1)
        XCTAssertEqual(outcome.removed.filter { $0.root == ItemOwnedFiles.episodeMapsRoot }.count, 2)
        XCTAssertEqual(outcome.removed.filter { $0.root == ItemOwnedFiles.pdfClipsRoot }.count, 2)
        XCTAssertEqual(try store.loadAllItemIds(), [other])
        let left = ((try? manager.contentsOfDirectory(atPath: journal.path)) ?? []).filter { $0.hasSuffix(".json") }
        XCTAssertTrue(left.isEmpty, "every file went, so the record is dropped")
    }

    /// The reason for the journal: a quit between the delete and the removal leaves the copied file with no row.
    func testAnInterruptedDeleteFinishesTheCopiedFilesAtTheNextLaunch() throws {
        let store = try store()
        try save(epub, in: store); try save(other, in: store)
        try store.saveOwnedOfflineAsset(epubAsset(epub))
        try write(sources.appending(path: "\(epub).epub")); try write(sources.appending(path: "\(other).epub"))
        try write(maps.appending(path: "\(epub)/a.json"))

        let purge = purge()
        let targets = ItemOwnedFiles.targets(forItem: epub, assets: try store.loadOwnedOfflineAssets(itemId: epub))
        _ = try purge.begin(itemIds: [epub], targets: targets)   // the intent is on disk
        try store.deleteItem(id: epub)                            // the rows went; the app was killed here
        XCTAssertTrue(exists(sources.appending(path: "\(epub).epub")))

        let outcome = purge.resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)
        XCTAssertFalse(exists(sources.appending(path: "\(epub).epub")))
        XCTAssertFalse(exists(maps.appending(path: epub)))
        XCTAssertTrue(exists(sources.appending(path: "\(other).epub")))
        XCTAssertTrue(outcome.kept.isEmpty)
        XCTAssertEqual(outcome.removed.count, targets.count)
    }

    func testAFailedRemovalOfACopiedFileIsRetriedAtTheNextLaunch() async throws {
        let store = try store()
        try save(epub, in: store)
        try store.saveOwnedOfflineAsset(epubAsset(epub))
        let file = sources.appending(path: "\(epub).epub")
        try write(file)
        let targets = ItemOwnedFiles.targets(forItem: epub, assets: try store.loadOwnedOfflineAssets(itemId: epub))

        let failing = purge(removeFile: { _ in throw CocoaError(.fileWriteNoPermission) })
        let first = await (try failing.deleting(itemIds: [epub], targets: targets) { try store.deleteItem(id: epub) }).value
        XCTAssertTrue(exists(file), "the removal failed")
        XCTAssertTrue(first.kept.contains { $0.root == ItemOwnedFiles.sourceDocumentsRoot })

        let second = purge().resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)
        XCTAssertFalse(exists(file))
        XCTAssertTrue(second.kept.isEmpty)
    }

    // MARK: Shared names and safety

    func testAnEpisodeMapFolderAnotherIdMapsToIsKept() async throws {
        let store = try store()
        // `a b` and `a-b` name one folder.
        for id in ["a b", "a-b"] { try save(id, in: store) }
        try write(maps.appending(path: "a-b/signature.shazamsignature"))
        let purge = purge()
        let outcome = await (try purge.deleting(
            itemIds: ["a b"], targets: ItemOwnedFiles.targets(forItem: "a b"), recheck: purge.storeRecheck(store: store)
        ) { try store.deleteItem(id: "a b") }).value
        XCTAssertTrue(exists(maps.appending(path: "a-b")), "a-b still uses the folder")
        XCTAssertEqual(
            Set(outcome.reappeared.map(\.root)),
            [ItemOwnedFiles.episodeMapsRoot, ItemOwnedFiles.preparedAudioRoot, ItemOwnedFiles.pdfClipsRoot],
            "every folder rule sees a-b")
    }

    func testAFolderNoOtherIdMapsToGoesWithTheItem() {
        let target = ItemOwnedFiles.targets(forItem: "a b").first { $0.root == ItemOwnedFiles.episodeMapsRoot }!
        let table: [(others: [String], free: Bool, note: String)] = [
            ([], true, "no other item"),
            (["a", "ab", "a--b"], true, "neighbours that map elsewhere"),
            (["a-b"], false, "the same folder"),
            (["A-B"], false, "case, on a volume that ignores it"),
            (["a!b"], false, "punctuation maps to a hyphen too"),
        ]
        for row in table {
            let state = ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { row.others })
            XCTAssertEqual(state, row.free ? .absent : .present, row.note)
        }
        XCTAssertEqual(
            ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { throw CocoaError(.fileReadUnknown) }),
            .unknown)
    }

    /// An empty id writes the folder `unknown` (the writers use `safeComponent` alone), so deleting an item whose id is
    /// literally `unknown` must not take it.
    func testAnItemNamedUnknownKeepsTheFolderAnEmptyIdWrites() {
        let target = ItemOwnedFiles.targets(forItem: "unknown").first { $0.root == ItemOwnedFiles.episodeMapsRoot }!
        XCTAssertEqual(target.relativePath, "unknown")
        XCTAssertEqual(
            ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { [""] }), .present,
            "an item with an empty id writes into `unknown`")
        XCTAssertEqual(ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { ["other"] }), .absent)
    }

    func testARootThatCannotLeaveItsFolderEvenWithAForgedRecord() throws {
        try write(support.appending(path: "SpokenMargins/library.sqlite"))
        let purge = purge()
        let forged = [
            PermanentDeletePurge.Target(root: ItemOwnedFiles.sourceDocumentsRoot, relativePath: "../SpokenMargins/library.sqlite"),
            PermanentDeletePurge.Target(root: ItemOwnedFiles.episodeMapsRoot, relativePath: ".."),
            PermanentDeletePurge.Target(root: ItemOwnedFiles.audiobooksRoot, relativePath: "../SpokenMargins"),
        ]
        let record = try purge.begin(itemIds: [epub], targets: forged)
        let outcome = purge.finish(record)
        XCTAssertEqual(outcome.kept.count, 3)
        XCTAssertTrue(exists(support.appending(path: "SpokenMargins/library.sqlite")))
        XCTAssertTrue(exists(maps))
    }
}
