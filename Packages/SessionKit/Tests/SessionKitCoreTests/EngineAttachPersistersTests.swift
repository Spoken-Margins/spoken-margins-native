import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// The store halves of attachPreparedTextAudio, attachTranscriptTimeline and attachPublisherChapters run off the main
/// thread, the engine halves on it (#2509). Real temporary SQLite throughout. Writes are counted by a second
/// connection's `PRAGMA data_version`, which moves whenever another connection commits; reads by the store's meter.
final class EngineAttachPersistersTests: XCTestCase {
    private var paths: [URL] = []
    private var watchers: [OpaquePointer] = []

    override func tearDown() {
        watchers.forEach { sqlite3_close($0) }
        watchers = []
        paths.forEach { try? FileManager.default.removeItem(at: $0) }
        paths = []
        super.tearDown()
    }

    private struct Rig {
        let store: SQLiteSessionStore
        let meter: StoreReadMeter
        let engine: SessionEngine
        let watcher: OpaquePointer
        var writes: () -> Int
    }

    private func rig(capable: Bool = true, seed items: [Item]) throws -> Rig {
        let path = FileManager.default.temporaryDirectory.appending(path: "attach-persisters-\(UUID()).sqlite")
        paths.append(path)
        let meter = StoreReadMeter()
        let store = try SQLiteSessionStore(path: path.path, readMeter: meter)
        for item in items { try store.seed(item: item) }
        var watcher: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path.path, &watcher, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let handle = try XCTUnwrap(watcher)
        watchers.append(handle)
        let capabilities: [String: [String]] = capable ? ["sync": ["canonical_persistence"], "playback": ["prerendered_audio"]] : [:]
        let engine = SessionEngine(profile: .init(id: "p", displayName: "P", capabilities: capabilities), repository: store)
        var last = Self.dataVersion(handle)
        var total = 0
        return Rig(store: store, meter: meter, engine: engine, watcher: handle, writes: {
            let now = Self.dataVersion(handle)
            total += now == last ? 0 : 1
            last = now
            return total
        })
    }

    private static func dataVersion(_ db: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(db, "PRAGMA data_version;", -1, &statement, nil)
        sqlite3_step(statement)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private let text = "The first sentence of the article. The second sentence follows it."

    private func textItem(status: String = "ready", media: ItemMedia? = nil) -> Item {
        Item(id: "item-1", title: "Article", mediaType: "text", text: text, externalReference: nil, status: status, media: media)
    }

    private func prepared() -> PreparedTextAudio {
        let segments = [
            MediaTimelineSegment(id: "p-0", startMs: 0, endMs: 3_000, startChar: 0, endChar: 33, text: ""),
            MediaTimelineSegment(id: "p-1", startMs: 3_000, endMs: 6_000, startChar: 34, endChar: text.count, text: ""),
        ]
        return PreparedTextAudio(
            normalizedText: text,
            media: ItemMedia(sourceType: .generatedTTSPrerendered, url: "file:///prepared/a.caf", durationMs: 6_000),
            timeline: MediaTimeline(segments: segments, chapters: [], durationMs: 6_000),
            createdAt: Date(timeIntervalSince1970: 1_760_000_000))
    }

    private func podcast(status: String = "needs_listening_map") -> Item {
        Item(id: "item-1", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil, externalReference: nil,
             status: status, media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///ep.mp3", durationMs: 600_000))
    }

    // MARK: Prepared text audio

    func testTextAudioPersistThenApplyEqualsTheSyncMethod() throws {
        let split = try rig(seed: [textItem()])
        let sync = try rig(seed: [textItem()])
        try split.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)
        try sync.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)

        let persisted = try split.engine.preparedTextAudioPersister(itemId: "item-1").persist(itemId: "item-1", prepared: prepared())
        XCTAssertNil(split.engine.currentItem?.media, "persisting alone changes nothing in the engine")
        let snapshot = try split.engine.attachPreparedTextAudio(persisted)
        let expected = try sync.engine.attachPreparedTextAudio(itemId: "item-1", prepared: prepared())

        XCTAssertEqual(try split.store.loadItem(id: "item-1"), try sync.store.loadItem(id: "item-1"))
        XCTAssertEqual(try split.store.loadTranscriptTimeline(itemId: "item-1")?.timeline, try sync.store.loadTranscriptTimeline(itemId: "item-1")?.timeline)
        XCTAssertEqual(split.engine.currentItem, sync.engine.currentItem)
        XCTAssertEqual(snapshot.itemId, expected.itemId)
        XCTAssertEqual(snapshot.targetType, expected.targetType)
        XCTAssertEqual(snapshot.targetId, expected.targetId)
        let stored = try split.store.loadItem(id: "item-1")
        XCTAssertEqual(stored.media, prepared().media)
        XCTAssertEqual(stored.transcriptId, "generated-transcript-item-1")
        XCTAssertEqual(stored.status, "needs_listening_map")
        XCTAssertEqual(try split.store.loadTranscriptTimeline(itemId: "item-1")?.timeline.segments.count, 2)
        XCTAssertEqual(split.engine.currentItem?.media, prepared().media)
    }

    func testTextAudioApplyReadsAndWritesNothing() throws {
        let rig = try rig(seed: [textItem()])
        try rig.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)
        let persisted = try rig.engine.preparedTextAudioPersister(itemId: "item-1").persist(itemId: "item-1", prepared: prepared())
        let writesBefore = rig.writes()
        let (_, reads) = try rig.meter.measuring { try rig.engine.attachPreparedTextAudio(persisted) }
        XCTAssertEqual(reads.count, 0, "the engine half reads no store row: \(reads.map(\.method))")
        XCTAssertEqual(rig.writes(), writesBefore, "the engine half writes no store row")
        XCTAssertEqual(rig.engine.currentItem?.media, prepared().media)
    }

    func testTextAudioGuardWritesNothing() throws {
        let native = textItem(media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///own.mp3", durationMs: 9_000))
        let rig = try rig(seed: [native])
        let writesBefore = rig.writes()
        let persisted = try rig.engine.preparedTextAudioPersister(itemId: "item-1").persist(itemId: "item-1", prepared: prepared())
        XCTAssertNil(persisted.updated)
        XCTAssertEqual(rig.writes(), writesBefore, "a refused item is not written")
        XCTAssertNil(try rig.store.loadTranscriptTimeline(itemId: "item-1"))
        let before = rig.engine.snapshot
        XCTAssertEqual(try rig.engine.attachPreparedTextAudio(persisted).itemId, before.itemId)
        XCTAssertEqual(try rig.store.loadItem(id: "item-1"), native)
    }

    func testTextAudioPersisterNeedsTheCapability() throws {
        let rig = try rig(capable: false, seed: [textItem()])
        XCTAssertThrowsError(try rig.engine.preparedTextAudioPersister(itemId: "item-1"))
        XCTAssertThrowsError(try rig.engine.attachPreparedTextAudio(itemId: "item-1", prepared: prepared()))
        XCTAssertNil(try rig.store.loadTranscriptTimeline(itemId: "item-1"))
    }

    // MARK: Source transcript timeline

    private func rawTimeline() -> TranscriptTimeline {
        MediaTimeline(segments: [
            MediaTimelineSegment(id: "b", startMs: 4_000, endMs: 8_000, text: "  second\n\n line  "),
            MediaTimelineSegment(id: "a", startMs: 0, endMs: 4_000, text: "first   line"),
        ], chapters: [], durationMs: 8_000)
    }

    func testTranscriptTimelinePersistThenApplyEqualsTheSyncMethod() throws {
        let split = try rig(seed: [podcast(status: "needs_transcript")])
        let sync = try rig(seed: [podcast(status: "needs_transcript")])
        try split.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)
        try sync.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)

        let persisted = try split.engine.transcriptTimelinePersister(itemId: "item-1").persist(itemId: "item-1", timeline: rawTimeline())
        XCTAssertNotEqual(split.engine.currentItem?.text, "first line second line", "persisting alone changes nothing in the engine")
        let snapshot = try split.engine.attachTranscriptTimeline(persisted)
        let expected = try sync.engine.attachTranscriptTimeline(itemId: "item-1", timeline: rawTimeline())

        let stored = try split.store.loadItem(id: "item-1")
        XCTAssertEqual(stored, try sync.store.loadItem(id: "item-1"))
        XCTAssertEqual(stored.text, "first line second line")
        XCTAssertEqual(stored.status, "needs_listening_map")
        XCTAssertEqual(stored.transcriptId, "transcript-item-1")
        let timeline = try XCTUnwrap(try split.store.loadTranscriptTimeline(itemId: "item-1")?.timeline)
        XCTAssertEqual(timeline, try sync.store.loadTranscriptTimeline(itemId: "item-1")?.timeline)
        XCTAssertEqual(timeline.segments.map(\.id), ["a", "b"])
        XCTAssertEqual(split.engine.currentItem, sync.engine.currentItem)
        XCTAssertEqual(snapshot.itemId, expected.itemId)
        XCTAssertEqual(snapshot.currentTranscriptSegmentId, expected.currentTranscriptSegmentId)
    }

    func testTranscriptTimelineApplyReadsAndWritesNothing() throws {
        let rig = try rig(seed: [podcast(status: "needs_transcript")])
        try rig.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)
        let persisted = try rig.engine.transcriptTimelinePersister(itemId: "item-1").persist(itemId: "item-1", timeline: rawTimeline())
        let writesBefore = rig.writes()
        let (_, reads) = try rig.meter.measuring { try rig.engine.attachTranscriptTimeline(persisted) }
        XCTAssertEqual(reads.count, 0, "the engine half reads no store row: \(reads.map(\.method))")
        XCTAssertEqual(rig.writes(), writesBefore, "the engine half writes no store row")
        XCTAssertEqual(rig.engine.currentItem?.text, "first line second line")
    }

    func testTranscriptTimelineWithoutTheCapabilityWritesNothing() throws {
        let rig = try rig(capable: false, seed: [podcast(status: "needs_transcript")])
        let writesBefore = rig.writes()
        XCTAssertThrowsError(try rig.engine.transcriptTimelinePersister(itemId: "item-1"))
        XCTAssertThrowsError(try rig.engine.attachTranscriptTimeline(itemId: "item-1", timeline: rawTimeline()))
        XCTAssertEqual(rig.writes(), writesBefore)
        XCTAssertNil(try rig.store.loadTranscriptTimeline(itemId: "item-1"))
    }

    // MARK: Publisher chapters

    private func chapters(_ source: PublisherChapterSource, _ titles: [String]) -> PublisherChapterCollection {
        PublisherChapterCollection(source: source, chapters: titles.enumerated().map { index, title in
            PublisherChapter(title: title, startMs: index * 300_000)
        })
    }

    func testPublisherChaptersPersistThenApplyEqualsTheSyncMethod() throws {
        let split = try rig(seed: [podcast()])
        let sync = try rig(seed: [podcast()])
        try split.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)
        try sync.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)
        let collection = chapters(.podcasting20JSON, ["Intro", "Topic"])

        let persisted = try split.engine.publisherChaptersPersister(itemId: "item-1").persist(itemId: "item-1", collection: collection)
        XCTAssertNil(split.engine.currentMap, "persisting alone changes nothing in the engine")
        let snapshot = try split.engine.attachPublisherChapters(persisted)
        let expected = try sync.engine.attachPublisherChapters(itemId: "item-1", collection: collection)

        let map = try XCTUnwrap(try split.store.loadListeningMap(itemId: "item-1"))
        XCTAssertEqual(map, try sync.store.loadListeningMap(itemId: "item-1"))
        XCTAssertEqual(map.id, "map-item-1-publisher-podcasting_2_json")
        XCTAssertEqual(map.chapters.map(\.title), ["Intro", "Topic"])
        XCTAssertEqual(try split.store.loadItem(id: "item-1"), try sync.store.loadItem(id: "item-1"))
        XCTAssertEqual(try split.store.loadItem(id: "item-1").status, "ready")
        XCTAssertEqual(try split.store.loadTranscriptTimeline(itemId: "item-1")?.id, "media-chapters-item-1")
        XCTAssertEqual(split.engine.currentMap, sync.engine.currentMap)
        XCTAssertEqual(split.engine.currentMap?.id, map.id)
        XCTAssertEqual(snapshot.itemId, expected.itemId)
    }

    func testPublisherChaptersApplyReadsAndWritesNothing() throws {
        let rig = try rig(seed: [podcast()])
        try rig.engine.prepareSpeechText(itemId: "item-1", targetType: .itemTextTTS)
        let persisted = try rig.engine.publisherChaptersPersister(itemId: "item-1")
            .persist(itemId: "item-1", collection: chapters(.podcasting20JSON, ["Intro", "Topic"]))
        let writesBefore = rig.writes()
        let (_, reads) = try rig.meter.measuring { try rig.engine.attachPublisherChapters(persisted) }
        XCTAssertEqual(reads.count, 0, "the engine half reads no store row: \(reads.map(\.method))")
        XCTAssertEqual(rig.writes(), writesBefore, "the engine half writes no store row")
        XCTAssertNotNil(rig.engine.currentMap)
    }

    func testPublisherChaptersGuardsWriteNothing() throws {
        let rig = try rig(seed: [podcast()])
        _ = try rig.engine.attachPublisherChapters(itemId: "item-1", collection: chapters(.podcasting20JSON, ["Best"]))
        let stored = try rig.store.loadListeningMap(itemId: "item-1")
        let writesBefore = rig.writes()

        let lower = try rig.engine.publisherChaptersPersister(itemId: "item-1")
            .persist(itemId: "item-1", collection: chapters(.timestampedDescription, ["Worse"]))
        XCTAssertNil(lower, "a lower-precedence source is refused")
        let empty = try rig.engine.publisherChaptersPersister(itemId: "item-1")
            .persist(itemId: "item-1", collection: PublisherChapterCollection(source: .podcasting20JSON, chapters: [PublisherChapter(title: "  ", startMs: 0)]))
        XCTAssertNil(empty, "chapters that normalise away are refused")
        XCTAssertEqual(rig.writes(), writesBefore, "a refused collection writes nothing")
        XCTAssertEqual(try rig.store.loadListeningMap(itemId: "item-1"), stored)
        let snapshot = rig.engine.snapshot
        XCTAssertEqual(try rig.engine.attachPublisherChapters(nil).itemId, snapshot.itemId)
    }
}
