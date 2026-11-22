import XCTest
@testable import SessionKit

/// #3769: which Files picks become collections, with real files. A titled link list picked on its own does; an untitled
/// one, a list inside a picked folder, a rejection and every other file go the way they always did.
final class LibraryCollectionPickRouteTests: XCTestCase {
    private var root: URL!
    private let version = LinkListFile.schemaVersion

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "collection-pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ path: String, _ text: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func list(title: String?, _ url: String = "https://example.com/a") -> String {
        let titleField = title.map { #""title": "\#($0)", "# } ?? ""
        return #"{"schemaVersion": "\#(version)", \#(titleField)"entries": [{"url": "\#(url)"}]}"#
    }

    func testOnlyATitledListPickedOnItsOwnBecomesACollection() throws {
        let titled = try write("week3.json", list(title: "Week 3 listening"))
        let untitled = try write("loose.json", list(title: nil))
        let blank = try write("blank.json", list(title: "   "))
        let edition = try write("edition.json", #"{"schemaVersion": "spoken-margins.listening-edition.v1", "title": "E"}"#)
        let split = LinkListPick.sort(files: [titled, untitled, blank, edition]).splittingCollections()

        XCTAssertEqual(split.collections.map(\.collectionTitle), ["Week 3 listening"])
        XCTAssertEqual(split.collections.first?.url, titled, "the importer needs the file itself")
        XCTAssertEqual(split.rest.lists.map(\.name), ["loose.json", "blank.json"], "untitled lists import as links, as before")
        XCTAssertEqual(split.rest.others, [edition], "an edition still goes to the edition import")
    }

    func testAListInsideAPickedFolderIsNeverItsOwnCollection() throws {
        try write("folder/titled.json", list(title: "Inside a folder"))
        let split = LinkListPick.sort(files: [], folders: [root.appending(path: "folder")]).splittingCollections()
        XCTAssertTrue(split.collections.isEmpty, "the folder is the collection")
        XCTAssertEqual(split.rest.lists.count, 1)
    }

    func testTheTitleIsTrimmedAndAPickOfOnlyTitledListsLeavesNothingElseToDo() throws {
        let titled = try write("a.json", list(title: "  Daily Brief  "))
        let split = LinkListPick.sort(files: [titled]).splittingCollections()
        XCTAssertEqual(split.collections.first?.collectionTitle, "Daily Brief")
        XCTAssertTrue(split.rest.isEmpty)
        XCTAssertFalse(split.rest.needsEditionImport(foldersPicked: false))
    }
}

/// #4720: one Undo after a bulk Move to Recently Deleted restores every item that moved.
final class LibraryTrashUndoBatchTests: XCTestCase {
    func testNothingMovedOffersNoUndo() {
        XCTAssertNil(LibraryTrashUndoBatch(moved: []))
    }

    func testOneMovedNamesItsTitle() throws {
        let batch = try XCTUnwrap(LibraryTrashUndoBatch(moved: [("a", "Morning brief")]))
        XCTAssertEqual(batch.name, "Morning brief")
        XCTAssertEqual(batch.restoredBanner(restoredIDs: ["a"]), "Restored Morning brief.")
    }

    func testManyMovedAreAllInTheUndoInOrderOnceEach() throws {
        let batch = try XCTUnwrap(LibraryTrashUndoBatch(moved: [("a", "A"), ("b", "B"), ("a", "A"), ("c", "C")]))
        XCTAssertEqual(batch.itemIDs, ["a", "b", "c"])
        XCTAssertEqual(batch.name, "3 items")
        XCTAssertTrue(batch.contains("b"))
        XCTAssertFalse(batch.contains("d"))
        XCTAssertEqual(batch.restoredBanner(restoredIDs: ["a", "b", "c"]), "Restored 3 items.")
    }

    func testThePartThatCameBackIsWhatTheBannerCounts() throws {
        let batch = try XCTUnwrap(LibraryTrashUndoBatch(moved: [("a", "A"), ("b", "B"), ("c", "C")]))
        XCTAssertEqual(batch.restoredBanner(restoredIDs: ["a", "c", "unrelated"]), "Restored 2 items.")
        XCTAssertEqual(batch.restoredBanner(restoredIDs: ["b"]), "Restored B.")
    }
}
