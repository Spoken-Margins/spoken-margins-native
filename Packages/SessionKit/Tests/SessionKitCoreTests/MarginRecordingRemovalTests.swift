import Foundation
import SQLite3
import SessionKit
import SessionKitPersistence
import XCTest

/// #2507 / #2510: permanent delete removes the item's recordings off the main thread. The decision is
/// `MarginRecordingCleanup`'s (tested in `MarginRecordingCleanupTests`); this covers that the scan and the file work
/// run in order behind `StoreReader`, on a real database and real files.
final class MarginRecordingRemovalTests: XCTestCase {
    private var root: URL!
    private var recordings: URL { root.appending(path: "SpokenMargins/interjections", directoryHint: .isDirectory) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "margin-recording-removal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func record(_ name: String) throws -> String {
        try Data("voice \(name)".utf8).write(to: recordings.appending(path: name))
        return "SpokenMargins/interjections/\(name)"
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: recordings.appending(path: name).path)
    }

    private func margin(_ id: String, item: String, audioPath: String) -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: "session-\(item)", targetType: .item, targetId: item,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: audioPath, audioStatus: "recorded",
            transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A Margin", status: "active"
        )
    }

    private var resolve: @Sendable (String) -> URL? {
        let root = self.root!
        return { path in
            let url = root.appending(path: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func store() throws -> SQLiteSessionStore {
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        for id in ["gone", "kept"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        return store
    }

    func testTheDeletedItemsRecordingsGoAndALiveItemsStay() async throws {
        let store = try store()
        try store.saveInterjection(margin("gone-1", item: "gone", audioPath: try record("gone-1.m4a")))
        try store.saveInterjection(margin("gone-2", item: "gone", audioPath: try record("gone-2.m4a")))
        try store.saveInterjection(margin("kept-1", item: "kept", audioPath: try record("kept-1.m4a")))
        let deleted = try store.loadInterjections(itemId: "gone").compactMap(\.audioPath)
        try store.deleteItem(id: "gone")

        let removed = await MarginRecordingRemoval.removeUnreferenced(
            deletedAudioPaths: deleted, store: store, within: root, resolve: resolve)

        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["gone-1.m4a", "gone-2.m4a"])
        XCTAssertFalse(exists("gone-1.m4a"))
        XCTAssertFalse(exists("gone-2.m4a"))
        XCTAssertTrue(exists("kept-1.m4a"), "a live item's recording is never touched")
    }

    func testAFileASurvivingMarginStillNamesStays() async throws {
        let store = try store()
        let shared = try record("shared.m4a")
        try store.saveInterjection(margin("gone-1", item: "gone", audioPath: shared))
        try store.saveInterjection(margin("kept-1", item: "kept", audioPath: shared))
        try store.deleteItem(id: "gone")

        let removed = await MarginRecordingRemoval.removeUnreferenced(
            deletedAudioPaths: [shared], store: store, within: root, resolve: resolve)

        XCTAssertEqual(removed, [])
        XCTAssertTrue(exists("shared.m4a"))
    }

    /// The leveled copies are found by the recording's content, so the hook has to run while the file is still there.
    func testTheHookSeesEachFileBeforeItIsRemoved() async throws {
        let store = try store()
        try store.saveInterjection(margin("gone-1", item: "gone", audioPath: try record("gone-1.m4a")))
        try store.deleteItem(id: "gone")
        let seen = HookLog()
        let directory = recordings

        await MarginRecordingRemoval.removeUnreferenced(
            deletedAudioPaths: ["SpokenMargins/interjections/gone-1.m4a"], store: store, within: root, resolve: resolve,
            beforeRemoving: { file in
                seen.add(file.lastPathComponent, stillThere: FileManager.default.fileExists(atPath: directory.appending(path: file.lastPathComponent).path))
            })

        XCTAssertEqual(seen.entries, ["gone-1.m4a:true"])
        XCTAssertFalse(exists("gone-1.m4a"))
    }

    func testNothingToRemoveDoesNotTouchTheStore() async throws {
        let store = try store()
        let removed = await MarginRecordingRemoval.removeUnreferenced(
            deletedAudioPaths: [], store: store, within: root, resolve: resolve)
        XCTAssertEqual(removed, [])
    }

    /// A refused scan must not leave a reference out and delete a recording a Margin still uses.
    func testAScanThatFailsRemovesNothing() async throws {
        let store = try store()
        let shared = try record("shared.m4a")
        try store.saveInterjection(margin("kept-1", item: "kept", audioPath: shared))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appending(path: "store.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = #"INSERT INTO records(kind,id,item_id,payload) VALUES('interjection','wrong-type','kept','{"id":"wrong-type","audioPath":7}');"#
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)

        let removed = await MarginRecordingRemoval.removeUnreferenced(
            deletedAudioPaths: [shared], store: store, within: root, resolve: resolve)

        XCTAssertEqual(removed, [])
        XCTAssertTrue(exists("shared.m4a"), "an unreadable survivor row means the scan refuses, so nothing is removed")
    }
}

private final class HookLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    func add(_ name: String, stillThere: Bool) { lock.lock(); log.append("\(name):\(stillThere)"); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return log }
}
