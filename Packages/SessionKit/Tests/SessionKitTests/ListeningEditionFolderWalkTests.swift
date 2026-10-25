import XCTest
@testable import SessionKit

final class ListeningEditionFolderWalkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "folder-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ path: String, _ text: String = "{}") throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func names(_ result: ListeningEditionFolderWalk.Result) -> [String] { result.urls.map(\.lastPathComponent) }

    func testFindsJSONAndIgnoresOtherFiles() throws {
        try write("a.json"); try write("b.JSON"); try write("notes.txt"); try write("book.pdf"); try write(".hidden.json")
        let result = ListeningEditionFolderWalk.collect(in: root)
        XCTAssertEqual(names(result), ["a.json", "b.JSON"])
        XCTAssertFalse(result.truncated)
    }

    func testEmptyFolder() {
        let result = ListeningEditionFolderWalk.collect(in: root)
        XCTAssertTrue(result.urls.isEmpty)
        XCTAssertFalse(result.truncated)
    }

    func testNestedFoldersAreWalked() throws {
        try write("top.json"); try write("sub/inner.json"); try write("sub/deeper/deep.json")
        XCTAssertEqual(Set(names(ListeningEditionFolderWalk.collect(in: root))), ["top.json", "inner.json", "deep.json"])
    }

    func testDepthCap() throws {
        try write("one/two/three.json")
        XCTAssertEqual(names(ListeningEditionFolderWalk.collect(in: root, maxDepth: 1)), [])
        XCTAssertEqual(names(ListeningEditionFolderWalk.collect(in: root, maxDepth: 2)), ["three.json"])
    }

    func testCountCapReportsTruncation() throws {
        for i in 0..<5 { try write("c\(i).json") }
        let result = ListeningEditionFolderWalk.collect(in: root, maxFiles: 3)
        XCTAssertEqual(result.urls.count, 3)
        XCTAssertTrue(result.truncated)
        let exact = ListeningEditionFolderWalk.collect(in: root, maxFiles: 5)
        XCTAssertEqual(exact.urls.count, 5)
        XCTAssertFalse(exact.truncated, "exactly at the cap is not truncated")
    }

    func testTwoCollectionsAndOneOtherJSONFeedTheBatch() throws {
        func make(_ title: String) -> ListeningEdition {
            ListeningEdition(title: title, text: title + " text", generator: "g", overview: "o",
                             scenes: [.init(title: "A", description: "d", summary: "s", startBlock: 1, endBlock: 1)])
        }
        try write("one.json", String(decoding: try make("One").encoded(), as: UTF8.self))
        try write("nested/two.json", String(decoding: try make("Two").encoded(), as: UTF8.self))
        try write("notes.json", #"{"hello": "world"}"#)
        let entries = ListeningEditionFolderWalk.collect(in: root).urls.enumerated().map { index, url in
            ListeningEditionBatch.Entry(id: index, name: url.lastPathComponent, data: (try? Data(contentsOf: url)) ?? Data())
        }
        let lines = ListeningEditionBatch.run(entries, existing: { _ in .none }, importOne: { _ in })
        XCTAssertEqual(lines.filter { $0.outcome == .imported }.count, 2)
        let summary = ListeningEditionBatch.summary(of: lines)
        XCTAssertTrue(summary.isFailure)
        XCTAssertTrue(summary.message.contains("Imported 2 of 3 files."), summary.message)
        XCTAssertTrue(summary.message.contains("notes.json"), summary.message)
        let cut = summary.appending(ListeningEditionFolderWalk.truncationNote())
        XCTAssertTrue(cut.message.hasPrefix(summary.message) && cut.message.hasSuffix(ListeningEditionFolderWalk.truncationNote()))
        XCTAssertEqual(cut.isFailure, summary.isFailure)
    }

    func testMessages() {
        XCTAssertTrue(ListeningEditionFolderWalk.emptyMessage(folderNames: ["Reading"]).contains("Reading"))
        XCTAssertTrue(ListeningEditionFolderWalk.truncationNote(maxFiles: 200).contains("200"))
    }
}
