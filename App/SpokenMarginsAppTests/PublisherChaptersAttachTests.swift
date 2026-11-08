import XCTest
import SessionKit
import SessionKitAudio
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #2509: an imported podcast's publisher chapters are saved off the main thread, and an engine replaced while the
/// save ran is not told.
@MainActor
final class PublisherChaptersAttachTests: XCTestCase {
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        func note() { lock.withLock { threads.append(Thread.isMainThread) } }
        var onMainThread: [Bool] { lock.withLock { threads } }
    }

    private func rig() throws -> (Gate1AppModel, SQLiteSessionStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "publisher-chapters-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveItem(Item(
            id: "episode-1", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/episode.mp3", durationMs: 900_000)
        ))
        return (model, store, root)
    }

    private let chapters = PublisherChapterCollection(
        source: .podcasting20JSON,
        chapters: [PublisherChapter(title: "Intro", startMs: 0), PublisherChapter(title: "Topic", startMs: 300_000)]
    )

    override func tearDown() {
        PublisherChaptersAttach.observeWrite = nil
        super.tearDown()
    }

    func testTheChaptersAreSavedOffTheMainThread() async throws {
        let (model, store, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = Writes()
        PublisherChaptersAttach.observeWrite = { writes.note() }
        let engine = try XCTUnwrap(model.engine)
        try await PublisherChaptersAttach.attach(chapters, itemId: "episode-1", engine: engine, model: model)
        XCTAssertEqual(writes.onMainThread, [false], "one save, and not on the main thread")
        XCTAssertEqual(try store.loadListeningMap(itemId: "episode-1")?.chapters.map(\.title), ["Intro", "Topic"])
    }

    func testAnEngineReplacedDuringTheSaveIsNotToldButTheChaptersAreKept() async throws {
        let (model, store, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try XCTUnwrap(model.engine)
        // The replacement lands while the save runs: the hook fires on the background thread, so hop to main.
        PublisherChaptersAttach.observeWrite = {
            DispatchQueue.main.async { MainActor.assumeIsolated { model.installEngine(try! model.makeEngine(store: try! XCTUnwrap(model.store))) } }
            Thread.sleep(forTimeInterval: 0.3)
        }
        try await PublisherChaptersAttach.attach(chapters, itemId: "episode-1", engine: old, model: model)
        XCTAssertFalse(model.engine === old, "the engine was replaced during the save")
        XCTAssertEqual(try store.loadListeningMap(itemId: "episode-1")?.chapters.map(\.title), ["Intro", "Topic"], "the save still stands")
    }
}
