import XCTest
@testable import SessionKit

/// #3767: link lists are found by their `schemaVersion`, in picked files and in picked folders, with real files.
final class LinkListPickTests: XCTestCase {
    private var root: URL!
    private let version = LinkListFile.schemaVersion

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "link-list-pick-\(UUID().uuidString)")
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

    private func linkList(_ urls: String...) -> String {
        let entries = urls.map { #"{"url": "\#($0)"}"# }.joined(separator: ",")
        return #"{"schemaVersion": "\#(version)", "entries": [\#(entries)]}"#
    }

    private let edition = #"{"schemaVersion": "spoken-margins.listening-edition.v1", "title": "An edition"}"#

    func testAPickedLinkListIsFoundAndAnEditionIsLeftToTheEditionImport() throws {
        let list = try write("brief.json", linkList("https://example.com/a", "https://example.com/b"))
        let other = try write("edition.json", edition)
        let pick = LinkListPick.sort(files: [list, other])
        XCTAssertEqual(pick.lists.map(\.name), ["brief.json"])
        XCTAssertEqual(pick.lists.first?.list.entries.map(\.url), ["https://example.com/a", "https://example.com/b"])
        XCTAssertEqual(pick.others, [other])
        XCTAssertTrue(pick.rejections.isEmpty)
        XCTAssertFalse(pick.isEmpty)
    }

    func testALinkListInAPickedFolderIsFoundWhateverItsNameOrDepth() throws {
        try write("morning.json", linkList("https://example.com/a"))
        try write("later/deeper/notes.json", linkList("https://example.com/b"))
        let pick = LinkListPick.sort(files: [], folders: [root])
        XCTAssertEqual(pick.lists.flatMap(\.list.entries).map(\.url), ["https://example.com/a", "https://example.com/b"])
        XCTAssertEqual(pick.folderFilePaths.count, 2)
        XCTAssertEqual(pick.folderOtherCount, 0)
        XCTAssertTrue(pick.others.isEmpty)
    }

    func testAFolderWithListsAndEditionsLeavesTheEditionsToTheEditionImport() throws {
        let listURL = try write("a-list.json", linkList("https://example.com/a"))
        try write("an-edition.json", edition)
        try write("random.json", #"{"hello": "world"}"#)
        let pick = LinkListPick.sort(files: [], folders: [root])
        XCTAssertEqual(pick.lists.map(\.name), ["a-list.json"])
        XCTAssertEqual(pick.folderFilePaths, [LinkListPick.filePath(listURL)])
        XCTAssertEqual(pick.folderOtherCount, 2)
        XCTAssertTrue(pick.needsEditionImport(foldersPicked: true))
    }

    func testAFolderOfOnlyLinkListsLeavesNothingForTheEditionImport() throws {
        try write("a.json", linkList("https://example.com/a"))
        try write("b.json", linkList("https://example.com/b"))
        let pick = LinkListPick.sort(files: [], folders: [root])
        XCTAssertFalse(pick.needsEditionImport(foldersPicked: true))
    }

    func testAFolderWithNoJSONStillGetsTheEditionImportsEmptyMessage() throws {
        try write("notes.txt", "https://example.com/a")
        let pick = LinkListPick.sort(files: [], folders: [root])
        XCTAssertTrue(pick.isEmpty)
        XCTAssertTrue(pick.needsEditionImport(foldersPicked: true))
        XCTAssertFalse(pick.needsEditionImport(foldersPicked: false))
    }

    func testTextAndMarkdownFilesInAFolderAreNeverLinkLists() throws {
        // Even a text file holding a full, valid link list is left alone: only `.json` is ever read.
        try write("list.txt", linkList("https://example.com/a"))
        try write("list.md", linkList("https://example.com/a"))
        try write("only-a-url.txt", "https://example.com/a")
        let pick = LinkListPick.sort(files: [], folders: [root])
        XCTAssertTrue(pick.isEmpty)
        XCTAssertEqual(pick.folderOtherCount, 0)
    }

    func testAJSONFileThatIsNotAnObjectWithAVersionIsLeftAlone() throws {
        let files = try [
            write("array.json", #"["https://example.com/a"]"#),
            write("bare-url.json", #""https://example.com/a""#),
            write("no-version.json", #"{"entries": [{"url": "https://example.com/a"}]}"#),
            write("broken.json", "{not json"),
            write("empty.json", ""),
        ]
        let pick = LinkListPick.sort(files: files)
        XCTAssertTrue(pick.isEmpty)
        XCTAssertEqual(Set(pick.others), Set(files))
    }

    func testAFileThatSaysItIsALinkListButCannotBeTakenIsNamedAndNotPassedOn() throws {
        let future = try write("future.json", #"{"schemaVersion": "spoken-margins.link-list.v2", "entries": []}"#)
        let inFolder = try write("sub/empty.json", #"{"schemaVersion": "\#(version)", "entries": []}"#)
        let pick = LinkListPick.sort(files: [future], folders: [root.appending(path: "sub")])
        XCTAssertEqual(pick.rejections.map(\.name), ["future.json", "empty.json"])
        XCTAssertTrue(pick.others.isEmpty)
        XCTAssertEqual(pick.folderFilePaths, [LinkListPick.filePath(inFolder)])
        XCTAssertFalse(pick.needsEditionImport(foldersPicked: true))
    }

    func testAnUnreadableFileGoesToTheEditionImportSoItIsReportedAsBefore() {
        let missing = root.appending(path: "gone.json")
        let pick = LinkListPick.sort(files: [missing])
        XCTAssertEqual(pick.others, [missing])
    }

    func testAnOversizedFileIsNotReadAndStaysWithTheEditionImport() throws {
        let big = root.appending(path: "big.json")
        try Data(count: LinkListPick.maxReadBytes + 1).write(to: big)
        let pick = LinkListPick.sort(files: [big])
        XCTAssertEqual(pick.others, [big])
    }

    func testTheFolderWalkLimitStillAppliesAndIsReported() throws {
        for index in 1...4 { try write("f\(index).json", linkList("https://example.com/\(index)")) }
        let pick = LinkListPick.sort(files: [], folders: [root], maxFolderFiles: 3)
        XCTAssertEqual(pick.lists.count, 3)
        XCTAssertTrue(pick.folderTruncated)
    }

    func testTheFolderWalkLimitIsSharedAcrossFolders() throws {
        try write("one/a.json", linkList("https://example.com/a"))
        try write("one/b.json", linkList("https://example.com/b"))
        try write("two/c.json", linkList("https://example.com/c"))
        let pick = LinkListPick.sort(files: [], folders: [root.appending(path: "one"), root.appending(path: "two")], maxFolderFiles: 2)
        XCTAssertEqual(pick.lists.count, 2)
        XCTAssertTrue(pick.folderTruncated)
    }
}
