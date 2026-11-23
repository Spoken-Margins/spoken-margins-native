import XCTest
@testable import SessionKit

/// #4683 PR 3b, Design section 2e: what "Add Link List to Spoken Margins" accepts, refuses and says, on a real
/// temporary handoff folder. The action itself runs with the app closed and only writes this folder (the `background`
/// condition): nothing here, or in the action, opens or imports anything.
final class LinkListShortcutActionTests: XCTestCase {
    private var base: URL!
    private var folder: LinkListHandoffFolder!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        folder = LinkListHandoffFolder(baseDirectory: base)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private let titled = """
    {"schemaVersion":"spoken-margins.link-list.v1","title":"Morning brief, November 23","entries":[
      {"url":"https://news.example.org/a","title":"A"},
      {"url":"https://news.example.org/b"},
      {"url":"https://feeds.example.org/show.xml","follow":true}]}
    """
    private let untitled = #"{"schemaVersion":"spoken-margins.link-list.v1","entries":[{"url":"https://news.example.org/a"},{"url":"https://news.example.org/b"}]}"#

    private func assertFailure(_ failure: LinkListShortcutAction.Failure, file: Data? = nil, text: String? = nil, line: UInt = #line) {
        XCTAssertThrowsError(try LinkListShortcutAction.run(file: file, text: text, folder: folder), line: line) { error in
            XCTAssertEqual(error as? LinkListShortcutAction.Failure, failure, line: line)
        }
        XCTAssertTrue(folder.pending().isEmpty, "a refused list leaves nothing behind", line: line)
    }

    func testATitledFileIsSavedAndTheDialogNamesItAndItsLinks() throws {
        let saved = try LinkListShortcutAction.run(file: Data(titled.utf8), text: nil, folder: folder)
        XCTAssertEqual(saved.title, "Morning brief, November 23")
        XCTAssertEqual(saved.linkCount, 3, "a show to follow is a link too")
        XCTAssertEqual(saved.dialog, "Saved “Morning brief, November 23” with 3 links. Open Spoken Margins to add them.")
        XCTAssertEqual(folder.pending().count, 1)
    }

    func testAnUntitledListAndASingleLinkReadRight() throws {
        XCTAssertEqual(try LinkListShortcutAction.run(file: nil, text: untitled, folder: folder).dialog,
                       "Saved a list with 2 links. Open Spoken Margins to add them.")
        let one = #"{"schemaVersion":"spoken-margins.link-list.v1","title":"Solo","entries":[{"url":"https://news.example.org/a"}]}"#
        XCTAssertEqual(try LinkListShortcutAction.run(file: nil, text: one, folder: folder).dialog,
                       "Saved “Solo” with 1 link. Open Spoken Margins to add them.")
    }

    func testTextMayBeAWholeReplyWithProseAroundTheList() throws {
        let reply = "Here is your brief:\n\n```json\n\(titled)\n```\nEnjoy!"
        let saved = try LinkListShortcutAction.run(file: nil, text: reply, folder: folder)
        XCTAssertEqual(saved.linkCount, 3)
        // What reaches the folder is the list itself, as JSON the app reads back, not the prose.
        let entry = try XCTUnwrap(folder.pending().first)
        guard case .linkList(let list) = folder.read(entry) else { return XCTFail("the saved file reads back as a list") }
        XCTAssertEqual(list.title, "Morning brief, November 23")
        XCTAssertEqual(list.entries.map(\.url), ["https://news.example.org/a", "https://news.example.org/b", "https://feeds.example.org/show.xml"])
        XCTAssertEqual(list.entries.map(\.follow), [false, false, true])
    }

    func testAFileHoldingAReplySavedAsText() throws {
        let reply = "Here you go:\n\(untitled)\n"
        XCTAssertEqual(try LinkListShortcutAction.run(file: Data(reply.utf8), text: nil, folder: folder).linkCount, 2)
    }

    func testAFileThatIsNotAListFallsBackToTheText() throws {
        let saved = try LinkListShortcutAction.run(file: Data("just some notes".utf8), text: untitled, folder: folder)
        XCTAssertEqual(saved.linkCount, 2)
        XCTAssertEqual(folder.pending().count, 1, "one list saved, not two")
    }

    func testTheFileWinsWhenBothAreLists() throws {
        let saved = try LinkListShortcutAction.run(file: Data(titled.utf8), text: untitled, folder: folder)
        XCTAssertEqual(saved.title, "Morning brief, November 23")
        XCTAssertEqual(folder.pending().count, 1)
    }

    // MARK: Refusals

    func testNothingGiven() {
        assertFailure(.nothingGiven)
        assertFailure(.nothingGiven, file: Data(), text: "  \n ")
        XCTAssertEqual(LinkListShortcutAction.Failure.nothingGiven.message, "Give this action a link list file or text.")
    }

    func testTextThatIsNotAList() {
        assertFailure(.notALinkList, text: "Remember the milk")
        assertFailure(.notALinkList, file: Data("[]".utf8))
        XCTAssertEqual(
            LinkListShortcutAction.Failure.notALinkList.message,
            "That isn't a Spoken Margins link list. Ask your AI for a \"spoken-margins.link-list.v1\" list.")
    }

    func testARefusalCarriesTheListersMessage() {
        let wrongVersion = #"{"schemaVersion":"spoken-margins.link-list.v9","entries":[{"url":"https://a.example.org/x"}]}"#
        XCTAssertThrowsError(try LinkListShortcutAction.run(file: Data(wrongVersion.utf8), text: nil, folder: folder)) { error in
            guard case .refused(let message)? = error as? LinkListShortcutAction.Failure else { return XCTFail("expected a refusal") }
            XCTAssertTrue(message.contains("v9"), message)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, message)
        }
        let noHTTPS = #"{"schemaVersion":"spoken-margins.link-list.v1","entries":[{"url":"http://a.example.org/x"}]}"#
        XCTAssertThrowsError(try LinkListShortcutAction.run(file: nil, text: noHTTPS, folder: folder)) { error in
            guard case .refused? = error as? LinkListShortcutAction.Failure else { return XCTFail("expected a refusal") }
        }
        XCTAssertTrue(folder.pending().isEmpty)
    }

    func testAnOverSizedFileOrReplyIsRefusedWholeWithTheSizeMessage() {
        // The marker is at the top, as a real list's is; the padding after it takes the whole over the 1 MB cap.
        let big = #"{"schemaVersion":"spoken-margins.link-list.v1","entries":[{"url":"https://a.example.org/x"}]}"# + String(repeating: " ", count: LinkListFile.maxFileBytes)
        assertFailure(.refused(LinkListFile.tooLargeMessage), file: Data(big.utf8))
        assertFailure(.refused(LinkListFile.tooLargeMessage), text: big)
    }

    func testAFullFolderThrowsTheFullMessageAndSavesNothingMore() throws {
        for _ in 0..<LinkListHandoffFolder.maxFiles {
            try LinkListShortcutAction.run(file: nil, text: untitled, folder: folder)
        }
        XCTAssertThrowsError(try LinkListShortcutAction.run(file: nil, text: untitled, folder: folder)) { error in
            XCTAssertEqual(error as? LinkListShortcutAction.Failure, .save(.full))
            XCTAssertEqual((error as? LinkListShortcutAction.Failure)?.message,
                           "Spoken Margins already has 20 lists waiting. Open the app to add them first.")
        }
        XCTAssertEqual(folder.pending().count, LinkListHandoffFolder.maxFiles)
    }

    func testAFolderThatCannotBeWrittenIsASaveFailureNotARawError() throws {
        // A plain file where the folder's parent should be: createDirectory fails.
        let blocker = base.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let blocked = LinkListHandoffFolder(baseDirectory: blocker)
        XCTAssertThrowsError(try LinkListShortcutAction.run(file: nil, text: untitled, folder: blocked)) { error in
            XCTAssertEqual(error as? LinkListShortcutAction.Failure, .save(.couldNotWrite))
        }
    }

    /// The save writes with the option that keeps a locked phone's Shortcut working (the `lock` condition).
    func testTheSaveUsesFileProtectionUntilFirstUnlock() throws {
        let box = OptionsBox()
        let writing = LinkListHandoffFolder(baseDirectory: base, writer: { data, url, options in
            box.set(options)
            try data.write(to: url, options: options)
        })
        _ = try LinkListShortcutAction.run(file: nil, text: untitled, folder: writing)
        XCTAssertEqual(box.value, LinkListHandoffFolder.writingOptions)
    }

    private final class OptionsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data.WritingOptions?
        var value: Data.WritingOptions? { lock.withLock { stored } }
        func set(_ options: Data.WritingOptions) { lock.withLock { stored = options } }
    }
}
