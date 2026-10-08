import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

final class MarginRecordingCleanupTests: XCTestCase {
    private var root: URL!
    private var recordings: URL { root.appending(path: "SpokenMargins/interjections", directoryHint: .isDirectory) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "margin-recording-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// Writes a recording the way the recorder does and returns the path a Margin row stores for it.
    @discardableResult
    private func record(_ name: String) throws -> String {
        try Data("voice \(name)".utf8).write(to: recordings.appending(path: name))
        return "SpokenMargins/interjections/\(name)"
    }

    private func margin(_ id: String, item: String, audioPath: String?) -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: "session-\(item)", targetType: .item, targetId: item,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: audioPath, audioStatus: audioPath == nil ? "none" : "recorded",
            transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A Margin", status: "active"
        )
    }

    /// Stands in for the app's resolver: a relative path lives under `root`, an absolute one is itself,
    /// and a file that isn't there resolves to nothing.
    private var resolve: (String) -> URL? {
        let root = self.root!
        return { path in
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appending(path: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: recordings.appending(path: name).path)
    }

    private func clean(deleted: [Interjection], surviving: [Interjection]) -> [URL] {
        MarginRecordingCleanup.removeFiles(deleted: deleted, surviving: surviving, within: root, resolve: resolve)
    }

    // MARK: The bug, through a real database

    func testPermanentDeleteTakesTheItemsRecordingsAndLeavesALiveItemsAlone() throws {
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        for id in ["gone", "kept"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        let goneOne = margin("gone-1", item: "gone", audioPath: try record("gone-1.m4a"))
        let goneTwo = margin("gone-2", item: "gone", audioPath: try record("gone-2.m4a"))
        let goneWritten = margin("gone-3", item: "gone", audioPath: nil)
        let keptOne = margin("kept-1", item: "kept", audioPath: try record("kept-1.m4a"))
        for row in [goneOne, goneTwo, goneWritten, keptOne] { try store.saveInterjection(row) }

        // What the app does: read the item's Margin rows, delete the item, then clean up the files.
        let deleted = try store.loadInterjections(itemId: "gone")
        XCTAssertEqual(Set(deleted.map(\.id)), ["gone-1", "gone-2", "gone-3"])
        try store.deleteItem(id: "gone")
        XCTAssertTrue(exists("gone-1.m4a"), "deleting the rows alone leaves the voice on the phone (#1035)")

        let removed = MarginRecordingCleanup.removeFiles(
            deleted: deleted, surviving: try store.loadAllInterjections(), within: root, resolve: resolve
        )

        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["gone-1.m4a", "gone-2.m4a"])
        XCTAssertFalse(exists("gone-1.m4a"))
        XCTAssertFalse(exists("gone-2.m4a"))
        XCTAssertTrue(exists("kept-1.m4a"), "a live item's recording is never touched")
        XCTAssertEqual(try store.loadAllInterjections().map(\.id), ["kept-1"])
    }

    func testEmptyingSeveralItemsAtOnceTakesEveryRecordingOfEach() throws {
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let ids = ["a", "b", "live"]
        for id in ids {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
            try store.saveInterjection(margin("\(id)-1", item: id, audioPath: try record("\(id)-1.m4a")))
            try store.saveInterjection(margin("\(id)-2", item: id, audioPath: try record("\(id)-2.m4a")))
        }
        let deleted = try ["a", "b"].flatMap { try store.loadInterjections(itemId: $0) }
        try store.deleteItems(ids: ["a", "b"])

        MarginRecordingCleanup.removeFiles(
            deleted: deleted, surviving: try store.loadAllInterjections(), within: root, resolve: resolve
        )

        for name in ["a-1", "a-2", "b-1", "b-2"] { XCTAssertFalse(exists("\(name).m4a"), name) }
        for name in ["live-1", "live-2"] { XCTAssertTrue(exists("\(name).m4a"), name) }
    }

    // MARK: A file a row still points at is never removed

    func testAFileASurvivingMarginStillNamesStays() throws {
        let shared = try record("shared.m4a")
        let deleted = [margin("d", item: "gone", audioPath: shared)]
        let surviving = [margin("s", item: "live", audioPath: shared)]
        XCTAssertEqual(clean(deleted: deleted, surviving: surviving), [])
        XCTAssertTrue(exists("shared.m4a"))
    }

    func testTheSameFileNamedAnotherWayStaysToo() throws {
        try record("shared.m4a")
        let absolute = recordings.appending(path: "shared.m4a").path
        let deleted = [margin("d", item: "gone", audioPath: "SpokenMargins/interjections/shared.m4a")]
        let surviving = [
            margin("s1", item: "live", audioPath: absolute),
            margin("s2", item: "live", audioPath: "SpokenMargins/interjections/../interjections/shared.m4a"),
        ]
        XCTAssertEqual(clean(deleted: deleted, surviving: surviving), [], "an absolute or dotted path to the same file")
        XCTAssertTrue(exists("shared.m4a"))
    }

    // MARK: Nothing outside the app's own folder, and nothing that isn't a recording file

    func testPathsThatLeaveTheApplicationSupportFolderAreLeftAlone() throws {
        let outsideFolder = FileManager.default.temporaryDirectory
            .appending(path: "outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideFolder) }
        let outside = outsideFolder.appending(path: "photo.m4a")
        try Data("not ours".utf8).write(to: outside)
        let linked = recordings.appending(path: "link.m4a")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        let deleted = [
            margin("absolute", item: "gone", audioPath: outside.path),
            margin("dotted", item: "gone", audioPath: "SpokenMargins/interjections/../../../\(outsideFolder.lastPathComponent)/photo.m4a"),
            margin("symlink", item: "gone", audioPath: "SpokenMargins/interjections/link.m4a"),
        ]

        XCTAssertEqual(clean(deleted: deleted, surviving: []), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testAFolderOrAMissingFileIsNotRemoved() throws {
        try FileManager.default.createDirectory(
            at: recordings.appending(path: "folder.m4a", directoryHint: .isDirectory), withIntermediateDirectories: true
        )
        let deleted = [
            margin("folder", item: "gone", audioPath: "SpokenMargins/interjections/folder.m4a"),
            margin("missing", item: "gone", audioPath: "SpokenMargins/interjections/never-recorded.m4a"),
            margin("empty", item: "gone", audioPath: ""),
        ]
        XCTAssertEqual(clean(deleted: deleted, surviving: []), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordings.appending(path: "folder.m4a").path))
    }

    func testTheRootItselfIsNeverRemoved() throws {
        let deleted = [margin("root", item: "gone", audioPath: root.path)]
        XCTAssertEqual(clean(deleted: deleted, surviving: []), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: Counting

    func testTwoRowsNamingOneFileRemoveItOnce() throws {
        let path = try record("twice.m4a")
        let deleted = [margin("one", item: "gone", audioPath: path), margin("two", item: "gone", audioPath: path)]
        XCTAssertEqual(clean(deleted: deleted, surviving: []).map(\.lastPathComponent), ["twice.m4a"])
        XCTAssertFalse(exists("twice.m4a"))
    }

    func testOtherFilesInTheSameFolderStay() throws {
        let path = try record("mine.m4a")
        try record("someone-elses.m4a")
        try Data("x".utf8).write(to: recordings.appending(path: "mine.m4a.partial"))
        _ = clean(deleted: [margin("m", item: "gone", audioPath: path)], surviving: [])
        XCTAssertFalse(exists("mine.m4a"))
        XCTAssertTrue(exists("someone-elses.m4a"))
        XCTAssertTrue(exists("mine.m4a.partial"), "only the file the row names")
    }

    func testNothingDeletedMeansNothingRemoved() throws {
        try record("kept.m4a")
        XCTAssertEqual(clean(deleted: [], surviving: [margin("k", item: "live", audioPath: "SpokenMargins/interjections/kept.m4a")]), [])
        XCTAssertTrue(exists("kept.m4a"))
    }
}
