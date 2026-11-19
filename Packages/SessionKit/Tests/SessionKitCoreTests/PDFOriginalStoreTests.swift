import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #4338 PR 1a: the kept original PDF, on a real temporary folder.
final class PDFOriginalStoreTests: XCTestCase {
    private var root: URL!
    private var store: PDFOriginalStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFOriginalStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = PDFOriginalStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let pdf = Data("%PDF-1.7 a small test document".utf8)

    func testWriteThenReadBackWithTheSameBytesAndHash() throws {
        let url = try store.write(pdf, itemId: "item-1")
        XCTAssertEqual(try Data(contentsOf: url), pdf)
        XCTAssertEqual(store.url(itemId: "item-1"), url)
        XCTAssertEqual(url.lastPathComponent, "original.pdf")
        XCTAssertEqual(store.sha256(itemId: "item-1"), SourceCatalogVerifier.sha256(pdf))
        XCTAssertEqual(store.sha256(itemId: "item-1")?.count, 64)
    }

    /// The import records this hash in the structured document before the item is saved, and the export screen later
    /// compares it with the kept file's: the two must be the same function of the same bytes.
    func testTheHashAnImportRecordsIsTheHashOfTheKeptFile() throws {
        try store.write(pdf, itemId: "item-1")
        XCTAssertEqual(PDFOriginalStore.sha256(of: pdf), store.sha256(itemId: "item-1"))
        XCTAssertEqual(PDFOriginalStore.sha256(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertNotEqual(PDFOriginalStore.sha256(of: pdf), PDFOriginalStore.sha256(of: pdf + Data([0x0a])))
    }

    func testASecondStoreOverTheSameFolderFindsItAfterARelaunch() throws {
        try store.write(pdf, itemId: "item-1")
        let relaunched = PDFOriginalStore(root: root)
        XCTAssertEqual(try relaunched.url(itemId: "item-1").map { try Data(contentsOf: $0) }, pdf)
    }

    func testNothingKeptGivesNoURLOrHash() {
        XCTAssertNil(store.url(itemId: "never-added"))
        XCTAssertNil(store.sha256(itemId: "never-added"))
        XCTAssertNil(store.url(itemId: ""))
        XCTAssertNil(store.sha256(itemId: ""))
    }

    func testAnEmptyItemIdCannotBeWritten() {
        XCTAssertThrowsError(try store.write(pdf, itemId: "")) { XCTAssertEqual($0 as? PDFOriginalStore.StoreError, .noItemId) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "nothing was created")
    }

    func testWritingAgainReplacesTheFileAndLeavesNoTemporaryFile() throws {
        try store.write(pdf, itemId: "item-1")
        let newer = Data("%PDF-1.7 the re-imported document".utf8)
        let url = try store.write(newer, itemId: "item-1")
        XCTAssertEqual(try Data(contentsOf: url), newer)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["original.pdf"])
    }

    func testTwoItemsKeepTheirOwnFiles() throws {
        try store.write(pdf, itemId: "item-1")
        try store.write(Data("other".utf8), itemId: "item-2")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.url(itemId: "item-1"))), pdf)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.url(itemId: "item-2"))), Data("other".utf8))
    }

    func testNastyIdsNeverEscapeTheRootOrShareAFolder() throws {
        let ids = ["../escape", "a/b", "a-b", "a_b", "A-1", "a-1", "item with spaces", "é", "e\u{301}", String(repeating: "x", count: 500), ".", ".."]
        for (index, id) in ids.enumerated() { try store.write(Data("\(index)".utf8), itemId: id) }
        for (index, id) in ids.enumerated() {
            let url = try XCTUnwrap(store.url(itemId: id), id)
            XCTAssertEqual(try Data(contentsOf: url), Data("\(index)".utf8), "\(id) kept its own bytes")
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"), "\(id) stays under the root")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, ids.count, "one folder per id")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    // MARK: Staging (a batch of large PDFs holds addresses and hashes, never bytes)

    private func source(_ data: Data, named name: String = "picked.pdf") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFOriginalStoreSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func entries(of itemId: String) throws -> [String] {
        let folder = try XCTUnwrap(store.folderURL(itemId: itemId))
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testStagingCopiesTheBytesAndHashesThemWithoutMakingTheItemsOriginalYet() throws {
        let picked = try source(pdf)
        let staged = try store.stage(copying: picked, itemId: "item-1")
        XCTAssertEqual(staged.sha256, PDFOriginalStore.sha256(of: pdf))
        XCTAssertEqual(try Data(contentsOf: staged.url), pdf)
        XCTAssertNil(store.url(itemId: "item-1"), "not the original until it is committed")
        XCTAssertEqual(try Data(contentsOf: picked), pdf, "the picked file is only read")
    }

    func testCommittingMakesTheStagedFileTheOriginalAndLeavesNoTemporaryFile() throws {
        let staged = try store.stage(copying: try source(pdf), itemId: "item-1")
        let url = try store.commit(staged)
        XCTAssertEqual(try Data(contentsOf: url), pdf)
        XCTAssertEqual(store.url(itemId: "item-1"), url)
        XCTAssertEqual(store.sha256(itemId: "item-1"), staged.sha256, "the recorded hash is the kept file's")
        XCTAssertEqual(try entries(of: "item-1"), ["original.pdf"])
    }

    func testCommittingReplacesAnEarlierOriginal() throws {
        try store.write(Data("%PDF old".utf8), itemId: "item-1")
        let staged = try store.stage(copying: try source(pdf), itemId: "item-1")
        try store.commit(staged)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.url(itemId: "item-1"))), pdf)
        XCTAssertEqual(try entries(of: "item-1"), ["original.pdf"])
    }

    func testDiscardingAStagedFileLeavesNothingAndKeepsAnEarlierOriginal() throws {
        try store.write(pdf, itemId: "item-1")
        let staged = try store.stage(copying: try source(Data("%PDF other".utf8)), itemId: "item-1")
        store.discard(staged)
        store.discard(staged) // nothing left to remove: no error
        XCTAssertEqual(try entries(of: "item-1"), ["original.pdf"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.url(itemId: "item-1"))), pdf)
    }

    /// Several chunks, and a size that is not a multiple of one: the copy and its hash must cover every byte.
    func testALargeFileIsCopiedWholeAndHashedLikeTheSameBytesInMemory() throws {
        let size = 3 * (1 << 20) + 12_345
        let big = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let staged = try store.stage(copying: try source(big), itemId: "big")
        XCTAssertEqual(staged.sha256, PDFOriginalStore.sha256(of: big))
        try store.commit(staged)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.url(itemId: "big"))), big)
    }

    func testAnEmptyFileStagesAndHashesAsEmpty() throws {
        let staged = try store.stage(copying: try source(Data()), itemId: "empty")
        XCTAssertEqual(staged.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testStagingAFileThatIsNotThereThrowsAndLeavesNoTemporaryFile() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try store.stage(copying: missing, itemId: "item-1"))
        XCTAssertEqual(try entries(of: "item-1"), [])
    }

    func testStagingForAnEmptyItemIdIsRefused() throws {
        XCTAssertThrowsError(try store.stage(copying: try source(pdf), itemId: "")) {
            XCTAssertEqual($0 as? PDFOriginalStore.StoreError, .noItemId)
        }
    }

    func testAStagedFileAQuitLeftBehindIsClearedAtLaunchOnceItIsOld() throws {
        let staged = try store.stage(copying: try source(pdf), itemId: "item-1")
        XCTAssertEqual(store.removeInterruptedWrites(now: Date()), 0, "a fresh one may still be in use")
        XCTAssertEqual(store.removeInterruptedWrites(now: Date().addingTimeInterval(PDFOriginalStore.abandonedAfter + 1)), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
    }

    func testTheStreamingHashMatchesTheInMemoryHashAtEveryChunkEdge() throws {
        for size in [0, 1, 7, 8, 9, 16, 17] {
            let data = Data((0..<size).map { UInt8($0 + 1) })
            XCTAssertEqual(
                try SourceCatalogVerifier.sha256(ofFileAt: try source(data), chunkSize: 8),
                SourceCatalogVerifier.sha256(data), "size \(size)")
        }
    }

    func testRemovingTheItemRemovesItsFolderAndOnlyThat() throws {
        try store.write(pdf, itemId: "item-1")
        try store.write(pdf, itemId: "item-2")
        try store.remove(itemId: "item-1")
        XCTAssertNil(store.url(itemId: "item-1"))
        XCTAssertNotNil(store.url(itemId: "item-2"))
        XCTAssertNoThrow(try store.remove(itemId: "item-1"), "removing what is not there is fine")
        XCTAssertNoThrow(try store.remove(itemId: ""))
    }

    func testAnInterruptedWriteIsIgnoredAndCleanedAndNeverTouchesTheKeptFile() throws {
        let url = try store.write(pdf, itemId: "item-1")
        let folder = url.deletingLastPathComponent()
        let leftover = folder.appendingPathComponent("original.pdf.\(UUID().uuidString).tmp")
        try Data("half a file".utf8).write(to: leftover)
        XCTAssertEqual(store.url(itemId: "item-1"), url, "the leftover is not the original")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.url(itemId: "item-1"))), pdf)
        XCTAssertEqual(store.removeInterruptedWrites(olderThan: 0), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(try Data(contentsOf: url), pdf)
        XCTAssertEqual(store.removeInterruptedWrites(olderThan: 0), 0)

        // An item whose only file is a leftover has no original.
        let second = folder.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(ItemOwnedFiles.itemOriginalsFolderName(itemId: "item-2")), isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: second.appendingPathComponent("original.pdf.x.tmp"))
        XCTAssertNil(store.url(itemId: "item-2"))
        XCTAssertEqual(store.removeInterruptedWrites(olderThan: 0), 1)
    }

    func testAnotherWritersTemporaryFileSurvivesAFinishedWriteAndALaunchCleanup() throws {
        let url = try store.write(pdf, itemId: "item-1")
        let folder = url.deletingLastPathComponent()
        let inFlight = folder.appendingPathComponent("original.pdf.\(UUID().uuidString).tmp")
        let abandoned = folder.appendingPathComponent("original.pdf.\(UUID().uuidString).tmp")
        try Data("being written".utf8).write(to: inFlight)
        try Data("quit halfway".utf8).write(to: abandoned)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: abandoned.path)

        XCTAssertEqual(store.removeInterruptedWrites(), 1, "only the abandoned one, at launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path), "a writer still running keeps its file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))

        try Data("quit halfway again".utf8).write(to: abandoned)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: abandoned.path)
        try store.write(Data("newer".utf8), itemId: "item-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path), "a finished write doesn't delete another writer's file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path), "it does clear an abandoned one")
        XCTAssertEqual(try Data(contentsOf: url), Data("newer".utf8))

        // The other writer's rename still works.
        XCTAssertEqual(rename(inFlight.path, url.path), 0)
        XCTAssertEqual(try Data(contentsOf: url), Data("being written".utf8))
    }

    func testRemovingInterruptedWritesWithNoFolderIsHarmless() {
        XCTAssertEqual(store.removeInterruptedWrites(olderThan: 0), 0)
    }

    func testAFolderAtTheFileNameIsNotAKeptPDF() throws {
        let folder = root.appendingPathComponent(try XCTUnwrap(ItemOwnedFiles.itemOriginalsFolderName(itemId: "item-1")), isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("original.pdf"), withIntermediateDirectories: true)
        XCTAssertNil(store.url(itemId: "item-1"))
    }

    // MARK: Permanent delete

    func testTheItemsOriginalsFolderIsAPermanentDeleteTarget() throws {
        let folder = try XCTUnwrap(ItemOwnedFiles.itemOriginalsFolderName(itemId: "item-1"))
        let targets = ItemOwnedFiles.targets(forItems: ["item-1", "item-2", ""])
        let originals = targets.filter { $0.root == ItemOwnedFiles.itemOriginalsRoot }
        XCTAssertEqual(originals.count, 2, "one per item with an id")
        XCTAssertTrue(originals.contains(.init(root: ItemOwnedFiles.itemOriginalsRoot, relativePath: folder, itemId: "item-1")))
        XCTAssertEqual(store.folderNameMatchesTarget("item-1"), folder)
        XCTAssertFalse(ItemOwnedFiles.isSharedFolderRoot(ItemOwnedFiles.itemOriginalsRoot), "a digest names one item's folder alone")
    }

    func testAPermanentDeleteRemovesTheKeptOriginalAndNotAnotherItemsOrALaterReimport() async throws {
        let originals = root.appendingPathComponent("ItemOriginals", isDirectory: true)
        let store = PDFOriginalStore(root: originals)
        try store.write(pdf, itemId: "gone")
        try store.write(pdf, itemId: "stays")
        let purge = PermanentDeletePurge(
            journalDirectory: root.appendingPathComponent("journal", isDirectory: true),
            roots: [.init(name: ItemOwnedFiles.itemOriginalsRoot, url: originals)]
        )
        _ = try await purge.deleting(itemIds: ["gone"], targets: ItemOwnedFiles.targets(forItems: ["gone"]), recheck: { _ in .absent }, delete: {}).value
        XCTAssertNil(store.url(itemId: "gone"))
        XCTAssertNotNil(store.url(itemId: "stays"))

        // An item imported again under the same id before the removal runs keeps its original.
        try store.write(pdf, itemId: "reimported")
        _ = try await purge.deleting(itemIds: ["reimported"], targets: ItemOwnedFiles.targets(forItems: ["reimported"]), recheck: { _ in .present }, delete: {}).value
        XCTAssertNotNil(store.url(itemId: "reimported"))
    }
}

private extension PDFOriginalStore {
    func folderNameMatchesTarget(_ itemId: String) -> String? { folderURL(itemId: itemId)?.lastPathComponent }
}
