import XCTest
@testable import SessionKit

/// #3769: the walk of a picked folder, with real temporary folders. Each test names a neighbouring input from the Design's table:
/// names, skips and placeholders, limits, and contents.
final class LibraryFolderWalkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func keys(_ result: LibraryFolderWalk.Result) -> [String] { result.members.map(\.key) }

    // MARK: names

    func testFilesComeBackInNaturalOrderWithTheirKinds() throws {
        for name in ["10.pdf", "2.pdf", "notes.txt", "essay.md", "readme.markdown", "book.epub", "show.mp3", "song.M4A", "talk.m4b", "clip.mp4", "photo.png"] {
            try write(name)
        }
        let result = LibraryFolderWalk.walk(root)
        let keys = keys(result)
        XCTAssertLessThan(try XCTUnwrap(keys.firstIndex(of: "2.pdf")), try XCTUnwrap(keys.firstIndex(of: "10.pdf")), "2 before 10")
        let kinds = Dictionary(uniqueKeysWithValues: result.members.map { ($0.key, $0.kind) })
        XCTAssertEqual(kinds["2.pdf"], .pdf)
        XCTAssertEqual(kinds["notes.txt"], .text)
        XCTAssertEqual(kinds["essay.md"], .markdown)
        XCTAssertEqual(kinds["readme.markdown"], .markdown)
        XCTAssertEqual(kinds["book.epub"], .epub)
        for audio in ["show.mp3", "song.M4A", "talk.m4b", "clip.mp4"] { XCTAssertEqual(kinds[audio], .audio, audio) }
        XCTAssertEqual(result.skippedOtherCount, 1, "the picture is counted, not named")
        XCTAssertTrue(result.notAdded.isEmpty)
        XCTAssertFalse(result.filesCapped || result.entriesCapped || result.hasDeeperFolders)
    }

    func testSubfoldersAreFlattenedInPathOrderWithRelativeKeys() throws {
        try write("Disc 2/01.mp3")
        try write("Disc 1/10.mp3")
        try write("Disc 1/2.mp3")
        try write("Disc 1.5/a.mp3")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(result), ["Disc 1/2.mp3", "Disc 1/10.mp3", "Disc 1.5/a.mp3", "Disc 2/01.mp3"])
    }

    func testNamesInDecomposedFormComeBackAsOneComposedKey() throws {
        try write("cafe\u{0301}.txt")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(result), ["caf\u{00E9}.txt"])
    }

    func testSameBytesUnderTwoNamesHaveTheSameHash() throws {
        try write("one.txt", "hello")
        try write("two.txt", "hello")
        try write("three.txt", "hello!")
        let result = LibraryFolderWalk.walk(root)
        let byKey = Dictionary(uniqueKeysWithValues: result.members.map { ($0.key, $0) })
        XCTAssertEqual(byKey["one.txt"]?.sha256, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(byKey["one.txt"]?.sha256, byKey["two.txt"]?.sha256)
        XCTAssertNotEqual(byKey["one.txt"]?.sha256, byKey["three.txt"]?.sha256)
        XCTAssertEqual(byKey["one.txt"]?.size, 5)
    }

    // MARK: skips and placeholders

    func testHiddenFilesAndHiddenFoldersAreSkipped() throws {
        try write(".DS_Store")
        try write(".hidden.pdf")
        try write(".secret/inside.pdf")
        try write("shown.pdf")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(result), ["shown.pdf"])
        XCTAssertEqual(result.skippedOtherCount, 0, "a hidden file is not counted as skipped")
    }

    func testAMarginsPacketFileOrPackageIsNamedNotImported() throws {
        try write("friend.spokenmargins")
        try write("Folder Packet.spokenmargins/manifest.json", "{}")
        try write("fine.pdf")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(result), ["fine.pdf"])
        XCTAssertEqual(Set(result.notAdded.map(\.key)), ["friend.spokenmargins", "Folder Packet.spokenmargins"])
        XCTAssertTrue(result.notAdded.allSatisfy { $0.reason == "Margins packets open on their own" })
        XCTAssertEqual(result.notAdded.first { $0.key == "friend.spokenmargins" }?.name, "friend.spokenmargins")
    }

    func testAnICloudPlaceholderIsReadUnderItsRealNameAndNotHashed() throws {
        try write(".Report.pdf.icloud", "stub")
        try write("Local.pdf")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(Set(keys(result)), ["Report.pdf", "Local.pdf"])
        let placeholder = try XCTUnwrap(result.members.first { $0.key == "Report.pdf" })
        XCTAssertTrue(placeholder.isNotDownloaded)
        XCTAssertNil(placeholder.sha256)
        XCTAssertEqual(placeholder.url?.lastPathComponent, "Report.pdf")
        XCTAssertEqual(placeholder.kind, .pdf)
        XCTAssertFalse(try XCTUnwrap(result.members.first { $0.key == "Local.pdf" }).isNotDownloaded)
    }

    func testAPlaceholderForAnUnsupportedTypeIsCountedAsOther() throws {
        try write(".Photo.png.icloud", "stub")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertTrue(result.members.isEmpty)
        XCTAssertEqual(result.skippedOtherCount, 1)
    }

    #if canImport(Darwin)
    func testAPackageFolderIsNotEntered() throws {
        try write("Thing.app/Contents/inside.pdf")
        try write("a.pdf")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(result), ["a.pdf"])
    }
    #endif

    // MARK: limits

    func testFoldersFourLevelsDownAreReadAndDeeperOnesAreFlagged() throws {
        try write("a/b/c/d/at-four.pdf")
        let ok = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(ok), ["a/b/c/d/at-four.pdf"])
        XCTAssertFalse(ok.hasDeeperFolders)

        try write("a/b/c/d/e/at-five.pdf")
        let deeper = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(deeper), ["a/b/c/d/at-four.pdf"], "the fifth level is not entered")
        XCTAssertTrue(deeper.hasDeeperFolders)
    }

    func testTwoHundredFilesFitAndTheTwoHundredAndFirstIsCut() throws {
        for index in 1...200 { try write(String(format: "%03d.txt", index)) }
        let exactly = LibraryFolderWalk.walk(root)
        XCTAssertEqual(exactly.members.count, 200)
        XCTAssertFalse(exactly.filesCapped)

        try write("201.txt")
        let over = LibraryFolderWalk.walk(root)
        XCTAssertEqual(over.members.count, 200)
        XCTAssertTrue(over.filesCapped)
        XCTAssertEqual(keys(over).last, "200.txt", "the first 200 in order are kept")
    }

    func testTheListingStopsAtTwoThousandEntries() throws {
        for index in 1...2_000 { try write(String(format: "p%04d.png", index)) }
        let exactly = LibraryFolderWalk.walk(root)
        XCTAssertFalse(exactly.entriesCapped)
        XCTAssertEqual(exactly.skippedOtherCount, 2_000)

        try write("p2001.png")
        let over = LibraryFolderWalk.walk(root)
        XCTAssertTrue(over.entriesCapped)
        XCTAssertEqual(over.skippedOtherCount, 2_000)
    }

    func testAMissingFolderGivesAnEmptyResult() {
        let result = LibraryFolderWalk.walk(root.appendingPathComponent("nope"))
        XCTAssertTrue(result.members.isEmpty && result.notAdded.isEmpty)
        XCTAssertEqual(result.skippedOtherCount, 0)
    }

    // MARK: contents

    func testAnEmptyFolderAndAFolderOfOnlyPicturesHaveNoMembers() throws {
        XCTAssertTrue(LibraryFolderWalk.walk(root).members.isEmpty)
        try write("a.png")
        try write("b.jpg")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertTrue(result.members.isEmpty)
        XCTAssertEqual(result.skippedOtherCount, 2)
    }

    func testALinkListBecomesOneMemberPerEntryAtTheListsPlace() throws {
        try write("a.pdf")
        try write("m-list.json", """
        {"schemaVersion":"spoken-margins.link-list.v1","title":"Brief","entries":[
          {"url":"https://example.com/one","title":"One"},{"url":"https://example.com/two"},{"url":"http://example.com/plain"},
          {"url":"https://example.com/three"}]}
        """)
        try write("z.pdf")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(result), ["a.pdf", "m-list.json#001", "m-list.json#002", "m-list.json#003", "z.pdf"])
        let entries = result.members.filter { $0.kind == .link }
        XCTAssertEqual(entries.map(\.address), ["https://example.com/one", "https://example.com/two", "https://example.com/three"])
        XCTAssertEqual(entries.first?.title, "One")
        XCTAssertNil(entries.first?.sha256)
        XCTAssertNil(entries.first?.url)
        XCTAssertEqual(result.notAdded.count, 1, "the http entry is named with the list's own reason")
        XCTAssertEqual(result.notAdded.first?.key, "m-list.json#003")
    }

    func testLinkEntriesDoNotCountTowardTheTwoHundredFiles() throws {
        let entries = (1...50).map { "{\"url\":\"https://example.com/\($0)\"}" }.joined(separator: ",")
        try write("000-list.json", "{\"schemaVersion\":\"spoken-margins.link-list.v1\",\"entries\":[\(entries)]}")
        for index in 1...199 { try write(String(format: "%03d.txt", index)) }
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(result.members.count, 249, "199 files and 50 entries")
        XCTAssertFalse(result.filesCapped)
    }

    func testAListeningEditionIsAMemberWithAHash() throws {
        try write("edition.json", "{\"schemaVersion\":\"\(ListeningEdition.version)\",\"title\":\"x\"}")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertEqual(keys(result), ["edition.json"])
        XCTAssertEqual(result.members.first?.kind, .edition)
        XCTAssertNotNil(result.members.first?.sha256)
    }

    func testAPackageJSONAndAnUnreadableJSONAreNamed() throws {
        try write("tool-settings.json", "{\"name\":\"x\",\"version\":\"1\"}")
        try write("broken.json", "{not json")
        try write("array.json", "[1,2]")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertTrue(result.members.isEmpty)
        XCTAssertEqual(Set(result.notAdded.map(\.key)), ["tool-settings.json", "broken.json", "array.json"])
        XCTAssertTrue(result.notAdded.allSatisfy { $0.reason == "Not a file the app can read" })
    }

    func testALinkListOfANewerVersionIsNamedWithItsOwnMessage() throws {
        try write("future.json", "{\"schemaVersion\":\"spoken-margins.link-list.v9\",\"entries\":[]}")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertTrue(result.members.isEmpty)
        XCTAssertEqual(result.notAdded.count, 1)
        XCTAssertTrue(result.notAdded[0].reason.contains("can't read"), result.notAdded[0].reason)
    }

    func testAnEmptyLinkListIsNamedNotImported() throws {
        try write("empty.json", "{\"schemaVersion\":\"spoken-margins.link-list.v1\",\"entries\":[]}")
        let result = LibraryFolderWalk.walk(root)
        XCTAssertTrue(result.members.isEmpty)
        XCTAssertEqual(result.notAdded.first?.key, "empty.json")
    }

    func testAFolderWithOneSupportedFileStillHasThatMember() throws {
        try write("only.pdf")
        XCTAssertEqual(keys(LibraryFolderWalk.walk(root)), ["only.pdf"])
    }
}
