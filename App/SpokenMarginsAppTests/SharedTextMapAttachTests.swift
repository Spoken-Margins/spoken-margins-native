import XCTest
import SessionKit
import SessionKitAudio
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #2509: a shared text map is saved off the main thread, and refused before anything is saved when the item plays.
@MainActor
final class SharedTextMapAttachTests: XCTestCase {
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        func note() { lock.withLock { threads.append(Thread.isMainThread) } }
        var onMainThread: [Bool] { lock.withLock { threads } }
    }

    private func model() throws -> (Gate1AppModel, SQLiteSessionStore, ListeningMap, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "shared-map-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveItem(Item(id: "shared-text", title: "Shared text", mediaType: "text", text: "One. Two.",
                                externalReference: "local", status: "ready"))
        let map = ListeningMap(id: "map-shared", itemId: "shared-text", overview: "",
                               chapters: [Chapter(id: "ch-1", title: "One", startChar: 0, endChar: 9, percent: 0)])
        return (model, store, map, root)
    }

    override func tearDown() {
        SharedTextMapAttach.observeWrite = nil
        super.tearDown()
    }

    func testTheMapIsSavedOffTheMainThread() async throws {
        let (model, store, map, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = Writes()
        SharedTextMapAttach.observeWrite = { writes.note() }
        try await SharedTextMapAttach.attach(map, model: model)
        XCTAssertEqual(writes.onMainThread, [false], "one write, and not on the main thread")
        XCTAssertEqual(try store.loadListeningMap(itemId: "shared-text")?.id, "map-shared")
    }

    func testAPlayingItemRefusesTheMapAndSavesNothing() async throws {
        let (model, store, map, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = Writes()
        SharedTextMapAttach.observeWrite = { writes.note() }
        var playing = SessionSnapshot()
        playing.itemId = "shared-text"
        playing.status = .playing
        model.snapshot = playing
        do {
            try await SharedTextMapAttach.attach(map, model: model)
            XCTFail("a playing item must refuse a new map")
        } catch {}
        XCTAssertEqual(writes.onMainThread, [])
        XCTAssertNil(try store.loadListeningMap(itemId: "shared-text"))
    }
}
