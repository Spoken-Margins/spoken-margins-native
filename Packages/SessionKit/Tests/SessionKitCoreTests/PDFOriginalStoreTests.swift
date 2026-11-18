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
        XCTAssertEqual(store.removeInterruptedWrites(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(try Data(contentsOf: url), pdf)
        XCTAssertEqual(store.removeInterruptedWrites(), 0)

        // An item whose only file is a leftover has no original.
        let second = folder.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(ItemOwnedFiles.itemOriginalsFolderName(itemId: "item-2")), isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: second.appendingPathComponent("original.pdf.x.tmp"))
        XCTAssertNil(store.url(itemId: "item-2"))
        XCTAssertEqual(store.removeInterruptedWrites(), 1)
    }

    func testRemovingInterruptedWritesWithNoFolderIsHarmless() {
        XCTAssertEqual(store.removeInterruptedWrites(), 0)
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
