@testable import SessionKit
import SessionKitPersistence
import XCTest

/// Where the pictures of a PDF's tables and figures are cut and kept (#3895).
final class PDFClipStoreTests: XCTestCase {
    private func region(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PDFNormalizedRect {
        PDFNormalizedRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Geometry

    func testTheCutFlipsTheRegionFromBottomLeftToTopLeft() throws {
        // The lower right quarter of a 1000 x 800 page picture is the bottom of the picture, not the top.
        let crop = try XCTUnwrap(PDFClipGeometry.crop(of: region(0.5, 0.0, 0.5, 0.25), pageWidth: 1000, pageHeight: 800))
        XCTAssertEqual(crop, .init(x: 500, y: 600, width: 500, height: 200, outputWidth: 500, outputHeight: 200))

        let top = try XCTUnwrap(PDFClipGeometry.crop(of: region(0.0, 0.75, 0.25, 0.25), pageWidth: 1000, pageHeight: 800))
        XCTAssertEqual(top, .init(x: 0, y: 0, width: 250, height: 200, outputWidth: 250, outputHeight: 200))
    }

    func testTheCutTakesWholePixelsOutwardAndStaysOnThePage() throws {
        let crop = try XCTUnwrap(PDFClipGeometry.crop(of: region(0.1005, 0.5005, 0.2, 0.2), pageWidth: 1000, pageHeight: 1000))
        XCTAssertEqual(crop.x, 100)
        XCTAssertEqual(crop.width, 201, "100.5 to 300.5 takes pixels 100 through 300")
        XCTAssertLessThanOrEqual(crop.y + crop.height, 1000)

        let edge = try XCTUnwrap(PDFClipGeometry.crop(of: region(0.9, 0.9, 0.2, 0.2), pageWidth: 100, pageHeight: 100))
        XCTAssertLessThanOrEqual(edge.x + edge.width, 100)
        XCTAssertGreaterThanOrEqual(edge.y, 0)
    }

    func testALargeCutIsScaledDownToTheLongestSideLimit() throws {
        let crop = try XCTUnwrap(PDFClipGeometry.crop(of: region(0, 0, 1, 0.5), pageWidth: 2000, pageHeight: 2000))
        XCTAssertEqual(crop.width, 2000)
        XCTAssertEqual(crop.outputWidth, 1400)
        XCTAssertEqual(crop.outputHeight, 700, "the shape is kept")
    }

    func testNoCutWhenThereIsNoAreaOrTheNumbersAreBad() {
        XCTAssertNil(PDFClipGeometry.crop(of: region(0.2, 0.2, 0, 0.2), pageWidth: 100, pageHeight: 100))
        XCTAssertNil(PDFClipGeometry.crop(of: region(.nan, 0.2, 0.2, 0.2), pageWidth: 100, pageHeight: 100))
        XCTAssertNil(PDFClipGeometry.crop(of: region(0.2, 0.2, 0.2, 0.2), pageWidth: 0, pageHeight: 100))
        XCTAssertNil(PDFClipGeometry.crop(of: region(1.2, 0.2, 0.2, 0.2), pageWidth: 100, pageHeight: 100), "off the page")
    }

    func testPageScaleIsTwiceUpToThePixelLimit() {
        XCTAssertEqual(PDFClipGeometry.pageScale(width: 612, height: 792), 2)
        XCTAssertEqual(PDFClipGeometry.pageScale(width: 2000, height: 3000), 2000.0 / 3000.0, accuracy: 1e-12)
        XCTAssertEqual(PDFClipGeometry.pageScale(width: 0, height: 0), 1)
    }

    // MARK: Files

    private func makeStore() -> (PDFClipStore, URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "clips-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (PDFClipStore(directory: base.appending(path: "PDFClips", directoryHint: .isDirectory)), base)
    }

    private func document(floatIds: [String]) -> StructuredDocument {
        StructuredDocument(
            extraction: .init(engine: "test", version: 2, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: "t", segments: [], markers: [],
            floats: floatIds.map {
                .init(id: $0, kind: .table, label: nil, pageIndex: 0, bounds: region(0.1, 0.1, 0.5, 0.2),
                      captionSegmentId: nil, textSegmentId: "s1")
            })
    }

    func testSavedClipsAreFoundByFloatAndOnlyForTheFloatsTheDocumentHas() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])

        try store.replaceClips(["float-p1-1": bytes, "float-p2-1": bytes, "stray": bytes], forItem: "item-a",
                               document: document(floatIds: ["float-p1-1", "float-p2-1"]))

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.url(forFloat: "float-p1-1", itemId: "item-a"))), bytes)
        XCTAssertNotNil(store.url(forFloat: "float-p2-1", itemId: "item-a"))
        XCTAssertNil(store.url(forFloat: "stray", itemId: "item-a"), "no float of that id in the document")
        XCTAssertNil(store.url(forFloat: "float-p1-1", itemId: "item-b"), "another item has none")
    }

    func testAReimportReplacesTheItemsClipsAndLeavesOtherItemsAlone() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = Data([1, 2, 3]), new = Data([4, 5, 6])
        try store.replaceClips(["float-p1-1": old, "float-p3-1": old], forItem: "item-a", document: document(floatIds: ["float-p1-1", "float-p3-1"]))
        try store.replaceClips(["float-p1-1": old], forItem: "item-b", document: document(floatIds: ["float-p1-1"]))

        try store.replaceClips(["float-p1-1": new], forItem: "item-a", document: document(floatIds: ["float-p1-1"]))

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.url(forFloat: "float-p1-1", itemId: "item-a"))), new)
        XCTAssertNil(store.url(forFloat: "float-p3-1", itemId: "item-a"), "a clip the new document doesn't have is gone")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.url(forFloat: "float-p1-1", itemId: "item-b"))), old)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testSavedFloatIdsListsOnlyTheFloatsAskedAboutThatHaveAFile() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: base.path) }
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try store.replaceClips(["float-p1-1": bytes, "float-p2-1": bytes], forItem: "item-a",
                               document: document(floatIds: ["float-p1-1", "float-p2-1"]))

        XCTAssertEqual(store.savedFloatIds(forItem: "item-a", among: ["float-p1-1", "float-p9-9"]), ["float-p1-1"],
                       "one with a file, one without")
        XCTAssertEqual(store.savedFloatIds(forItem: "item-a", among: ["float-p1-1", "float-p2-1"]), ["float-p1-1", "float-p2-1"])
        XCTAssertEqual(store.savedFloatIds(forItem: "item-a", among: []), [])
        XCTAssertEqual(store.savedFloatIds(forItem: "item-a", among: ["", "../escape", "float-p1-1.jpg"]), [],
                       "an id that names no file, or a file name given as an id, is not saved")
        XCTAssertEqual(store.savedFloatIds(forItem: "item-b", among: ["float-p1-1"]), [], "another item has none")
        XCTAssertEqual(store.savedFloatIds(forItem: "", among: ["float-p1-1"]), [], "no item, no folder")
    }

    func testSavedFloatIdsIsEmptyWhenTheFolderIsMissingOrWasCleared() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: base.path) }
        XCTAssertEqual(store.savedFloatIds(forItem: "item-a", among: ["float-p1-1"]), [], "the store's own folder is not there yet")

        try store.replaceClips(["float-p1-1": Data([1])], forItem: "item-a", document: document(floatIds: ["float-p1-1"]))
        XCTAssertEqual(store.savedFloatIds(forItem: "item-a", among: ["float-p1-1"]), ["float-p1-1"])
        try store.replaceClips([:], forItem: "item-a", document: document(floatIds: []))
        XCTAssertEqual(store.savedFloatIds(forItem: "item-a", among: ["float-p1-1"]), [], "a re-import with no clips clears the folder")
    }

    func testTheClipsSavedNoticeAndItsItemKeyAreFixedNames() {
        XCTAssertEqual(PDFClipStore.didSaveClipsNotification.rawValue, "SpokenMargins.PDFClipStore.didSaveClips")
        XCTAssertEqual(PDFClipStore.itemIdKey, "itemId")
    }

    func testNoClipsToKeepRemovesTheFolder() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.replaceClips(["float-p1-1": Data([1])], forItem: "item-a", document: document(floatIds: ["float-p1-1"]))
        let folder = try XCTUnwrap(store.folder(forItem: "item-a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try store.replaceClips([:], forItem: "item-a", document: document(floatIds: []))

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(store.url(forFloat: "float-p1-1", itemId: "item-a"))
        XCTAssertNoThrow(try store.replaceClips([:], forItem: "item-never-had-any", document: nil))
    }

    func testEmptyDataAndUnsafeNamesAreNotWritten() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.replaceClips(["float-p1-1": Data(), "../escape": Data([1]), "": Data([1])], forItem: "item-a",
                               document: document(floatIds: ["float-p1-1", "../escape", ""]))

        XCTAssertNil(store.url(forFloat: "float-p1-1", itemId: "item-a"), "an empty picture is no picture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appending(path: "escape.jpg").path))
        XCTAssertEqual(PDFClipStore.fileName(forFloat: "../escape"), "..-escape.jpg", "separators never reach the path")
        XCTAssertNil(PDFClipStore.fileName(forFloat: ""))
    }

    func testAnItemIdWithNoFolderOfItsOwnSavesNothing() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        for id in ["", ".", ".."] {
            XCTAssertNil(store.folder(forItem: id), "[\(id)]")
            try store.replaceClips(["float-p1-1": Data([1])], forItem: id, document: document(floatIds: ["float-p1-1"]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testRemoveClipsTakesTheFolder() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.replaceClips(["float-p1-1": Data([1])], forItem: "item-a", document: document(floatIds: ["float-p1-1"]))
        try store.removeClips(forItem: "item-a")
        XCTAssertNil(store.url(forFloat: "float-p1-1", itemId: "item-a"))
        XCTAssertNoThrow(try store.removeClips(forItem: "item-a"))
    }

    // MARK: A permanent delete takes them

    func testPermanentDeleteNamesTheItemsClipFolderTheSameWayTheStoreDoes() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        for id in ["item-a", "item with spaces", "a/b"] {
            let target = try XCTUnwrap(ItemOwnedFiles.targets(forItem: id).first { $0.root == ItemOwnedFiles.pdfClipsRoot }, id)
            XCTAssertEqual(target.relativePath, store.folder(forItem: id)?.lastPathComponent, id)
            XCTAssertEqual(target.itemId, id)
        }
        XCTAssertNil(ItemOwnedFiles.targets(forItem: "").first { $0.root == ItemOwnedFiles.pdfClipsRoot })
        XCTAssertTrue(ItemOwnedFiles.isSharedFolderRoot(ItemOwnedFiles.pdfClipsRoot))
    }

    func testAClipFolderAnotherIdMapsToIsKeptByAPurge() throws {
        // "a b" and "a-b" share a folder name; deleting one must not take the other's pictures.
        let target = try XCTUnwrap(ItemOwnedFiles.targets(forItem: "a b").first { $0.root == ItemOwnedFiles.pdfClipsRoot })
        let state = ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { ["a-b"] })
        XCTAssertEqual(state, .present)
        XCTAssertEqual(ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { ["other"] }), .absent)
    }

    // MARK: The Timeline asks what is there

    func testAvailableClipsComeFromOneListingOfTheItemsFolder() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try store.replaceClips(["float-p1-1": bytes, "float-p2-1": bytes], forItem: "item-a",
                               document: document(floatIds: ["float-p1-1", "float-p2-1", "float-p3-1"]))

        let available = store.available(forItem: "item-a")
        XCTAssertTrue(available.contains(floatId: "float-p1-1"))
        XCTAssertTrue(available.contains(floatId: "float-p2-1"))
        XCTAssertFalse(available.contains(floatId: "float-p3-1"), "the document has it, no picture was cut")
        XCTAssertFalse(available.contains(floatId: nil))
        XCTAssertFalse(available.contains(floatId: ""))
        XCTAssertFalse(available.contains(floatId: "../float-p1-1"), "an id that is not a file name is never a hit")

        XCTAssertTrue(store.available(forItem: "item-b").isEmpty, "another item has none of them")
        XCTAssertEqual(store.available(forItem: "item-b"), .none)
        XCTAssertEqual(store.available(forItem: ""), .none, "an item with no folder of its own")
    }

    func testAvailableClipsIgnoreFilesThatAreNotClipsAndFollowAReplace() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try store.replaceClips(["float-p1-1": bytes], forItem: "item-a", document: document(floatIds: ["float-p1-1"]))
        let folder = try XCTUnwrap(store.folder(forItem: "item-a"))
        try Data([1]).write(to: folder.appending(path: "float-p9-9.txt"))
        XCTAssertFalse(store.available(forItem: "item-a").contains(floatId: "float-p9-9"))

        try store.replaceClips(["float-p2-1": bytes], forItem: "item-a", document: document(floatIds: ["float-p1-1", "float-p2-1"]))
        let after = store.available(forItem: "item-a")
        XCTAssertFalse(after.contains(floatId: "float-p1-1"), "a re-import leaves no stale picture")
        XCTAssertTrue(after.contains(floatId: "float-p2-1"))

        try store.removeClips(forItem: "item-a")
        XCTAssertEqual(store.available(forItem: "item-a"), .none)
    }

    func testTheListingChangesWhenTheFolderIsReplacedEvenWithTheSameFileNames() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(store.available(forItem: "item-a").stamp, 0, "no folder, no stamp")

        let first = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        try store.replaceClips(["float-p1-1": first], forItem: "item-a", document: document(floatIds: ["float-p1-1"]))
        let listed = store.available(forItem: "item-a")
        XCTAssertGreaterThan(listed.stamp, 0)
        XCTAssertEqual(store.available(forItem: "item-a"), listed, "nothing changed, nothing differs")

        // Put the folder's date far in the past, as if the first import was long ago, then re-import the same
        // float ids with new pictures: the file names are the same, the listing is not.
        let folder = try XCTUnwrap(store.folder(forItem: "item-a"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: folder.path)
        let old = store.available(forItem: "item-a")
        XCTAssertEqual(old.stamp, 1_000)
        try store.replaceClips(["float-p1-1": Data([0xFF, 0xD8, 0x02, 0xFF, 0xD9])], forItem: "item-a",
                               document: document(floatIds: ["float-p1-1"]))
        let after = store.available(forItem: "item-a")
        XCTAssertTrue(after.contains(floatId: "float-p1-1"))
        XCTAssertNotEqual(after, old, "a reader that kept the old pictures can tell the files changed")
    }

    func testTheSavedJPEGIsReadBackByFloatOrIsNil() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        try store.replaceClips(["float-p1-1": bytes], forItem: "item-a", document: document(floatIds: ["float-p1-1"]))
        XCTAssertEqual(store.data(forFloat: "float-p1-1", itemId: "item-a"), bytes)
        XCTAssertNil(store.data(forFloat: "float-p2-1", itemId: "item-a"))
        XCTAssertNil(store.data(forFloat: "float-p1-1", itemId: "item-b"))
        XCTAssertNil(store.data(forFloat: "", itemId: "item-a"))
    }

    // MARK: The import carries them

    func testAFilesImportCarriesTheClipsToTheSaveAndNeverToATextFile() throws {
        let built = StructuredDocumentBuilder.build(lines: [
            .init(text: "Paper", role: .title, pageIndex: 0),
            .init(text: "Cell A | Cell B", role: .table, pageIndex: 0, bounds: region(0.2, 0.60, 0.5, 0.02)),
            .init(text: "1 | 2", role: .table, pageIndex: 0, bounds: region(0.2, 0.57, 0.5, 0.02)),
        ], engine: "test", version: 2, pageCount: 1)
        let pictures = ["float-p1-1": Data([1, 2, 3])]

        let pdf = try SourceFileItemBuilder.prepare(
            ImportedSourceText(text: built.text, documentStructure: nil, structuredDocument: built, title: "Paper", clips: pictures),
            fileURL: URL(fileURLWithPath: "/tmp/Paper.pdf"), itemId: "item-pdf", createdAt: Date())
        XCTAssertEqual(pdf.clips, pictures)
        XCTAssertEqual(pdf.structuredDocument?.floats.map(\.id), ["float-p1-1"], "the ids the pictures are keyed by are the document's")

        let text = try SourceFileItemBuilder.prepare(
            ImportedSourceText(text: "Just some words.", documentStructure: nil, clips: pictures),
            fileURL: URL(fileURLWithPath: "/tmp/Notes.txt"), itemId: "item-txt", createdAt: Date())
        XCTAssertEqual(text.clips, [:], "a file with no document has nothing to attach them to")
    }
}
