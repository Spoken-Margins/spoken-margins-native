import Foundation
import XCTest
@testable import SessionKit

final class ListeningSignalRecorderTests: XCTestCase {
    private static let fixture = "Contracts/fixtures/listening-signals/i4-engagement-sample.jsonl"
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("listening-signals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: Format

    func testEveryEventTypeRoundTrips() throws {
        let source = ListeningSignalSource(id: "source-1", title: "Systems Weekly", subscriptionKind: "podcast_feed", contentKind: "podcast", categories: ["technology"])
        let item = ListeningSignalItem(id: "entry-1", title: "Queues and clocks", publishedAt: Self.time("2026-09-01T08:00:00Z"), durationSeconds: 900)
        let events: [ListeningSignalEvent] = [
            .itemPublished, .listened(seconds: 42.5), .margin(kind: .spoken, length: 14), .margin(kind: .written, length: 184),
            .share, .export(packetId: "package-1", marginCount: 2), .export(packetId: nil, marginCount: 1),
            .packetImport(packetId: "package-2", fromOther: true, marginCount: 3), .dismiss, .finish,
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for event in events {
            let signal = ListeningSignal(event: event, at: Self.time("2026-09-02T19:00:00Z"), source: source, item: item)
            let data = try encoder.encode(signal)
            XCTAssertEqual(try decoder.decode(ListeningSignal.self, from: data), signal, event.name)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["schema_version"] as? String, "i4-engagement.1")
            XCTAssertEqual(object["event"] as? String, event.name)
        }
        let unknownItem = ListeningSignal(event: .packetImport(packetId: "p", fromOther: true, marginCount: 1), at: Self.time("2026-09-02T19:00:00Z"), source: source, item: nil)
        XCTAssertEqual(try decoder.decode(ListeningSignal.self, from: encoder.encode(unknownItem)), unknownItem)
    }

    func testRecorderWritesThePublishedFixture() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        Self.recordSampleScenario(recorder)
        recorder.flush()
        let written = try String(contentsOf: log, encoding: .utf8)
        if ProcessInfo.processInfo.environment["UPDATE_I4_FIXTURE"] == "1" {
            try written.write(to: Self.path(Self.fixture), atomically: true, encoding: .utf8)
        }
        let published = try String(contentsOf: Self.path(Self.fixture), encoding: .utf8)
        XCTAssertEqual(written, published, "the recorder's output changed; rerun with UPDATE_I4_FIXTURE=1 and update the I4 schema to match")
        XCTAssertEqual(try ListeningSignalRecorder.read(Self.path(Self.fixture)).count, published.split(separator: "\n").count)
    }

    // MARK: Listening intervals

    func testTicksCoalesceIntoOneIntervalUntilPlaybackStops() throws {
        let recorder = makeRecorder()
        let (source, item) = Self.podcast
        let start = Self.time("2026-09-02T19:00:00Z")
        for tick in 0...120 { recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(Double(tick) * 0.5)) }
        recorder.endListening()
        recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(500))
        let rows = recorder.signals()
        XCTAssertEqual(rows.map(\.event), [.listened(seconds: 60)], "one row per interval, not per tick; a lone tick is not listening")
        XCTAssertEqual(rows.first?.at, start)
    }

    func testGapsItemSwitchesAndLongListeningSplitIntervals() throws {
        let recorder = makeRecorder()
        let (source, item) = Self.podcast
        let other = ListeningSignalItem(id: "entry-2", title: "Other", publishedAt: item.publishedAt)
        let start = Self.time("2026-09-02T19:00:00Z")
        for second in 0...20 { recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(Double(second))) }
        // Paused without the ticker stopping cleanly (app suspended): a gap closes the interval.
        for second in 60...70 { recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(Double(second))) }
        for second in 71...81 { recorder.noteListening(source: source, item: other, at: start.addingTimeInterval(Double(second))) }
        for second in 100...800 { recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(Double(second))) }
        let rows = recorder.signals()
        XCTAssertEqual(rows.map(\.event), [
            .listened(seconds: 20), .listened(seconds: 10), .listened(seconds: 10),
            .listened(seconds: 300), .listened(seconds: 300), .listened(seconds: 100),
        ])
        XCTAssertEqual(rows.map { $0.item?.id }, ["entry-1", "entry-1", "entry-2", "entry-1", "entry-1", "entry-1"])
    }

    func testRecordingIsBufferedOffTheCallersThread() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        let (source, item) = Self.podcast
        recorder.record(.finish, source: source, item: item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "record returns before any file I/O")
        recorder.flush()
        XCTAssertEqual(ListeningSignalRecorder.read(log).map(\.event), [.finish])
        recorder.record(.dismiss, source: source, item: item)
        recorder.flush()
        XCTAssertEqual(ListeningSignalRecorder.read(log).map(\.event), [.finish, .dismiss], "the log is only appended to")
    }

    func testAClosedIntervalIsWrittenWithoutWaitingForTheFlushDelay() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        let (source, item) = Self.podcast
        let start = Self.time("2026-09-02T19:00:00Z")
        for second in 0...30 { recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(Double(second))) }
        recorder.endListening()
        _ = recorder.writeError // waits for the queue, without flushing
        XCTAssertEqual(ListeningSignalRecorder.read(log).map(\.event), [.listened(seconds: 30)],
                       "a paused app can be suspended before a delayed write runs")
    }

    func testAScheduledFlushWritesWithoutBeingAsked() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 0.05)
        let (source, item) = Self.podcast
        recorder.record(.share, source: source, item: item)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: log.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(ListeningSignalRecorder.read(log).map(\.event), [.share])
    }

    func testImportOfOwnExportIsNotFromOther() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let (source, item) = Self.podcast
        let first = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        first.record(.export(packetId: "package-mine", marginCount: 2), source: source, item: item)
        first.flush()
        // A later launch reads earlier exports back from the file.
        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        recorder.recordPacketImport(packetId: "package-mine", marginCount: 2, source: source, item: item)
        recorder.recordPacketImport(packetId: "package-theirs", marginCount: 1, source: source, item: nil)
        recorder.record(.export(packetId: "package-new", marginCount: 1), source: source, item: item)
        recorder.recordPacketImport(packetId: "package-new", marginCount: 1, source: source, item: item)
        XCTAssertEqual(recorder.signals().map(\.event).suffix(4), [
            .packetImport(packetId: "package-mine", fromOther: false, marginCount: 2),
            .packetImport(packetId: "package-theirs", fromOther: true, marginCount: 1),
            .export(packetId: "package-new", marginCount: 1),
            .packetImport(packetId: "package-new", fromOther: false, marginCount: 1),
        ])
    }

    // MARK: Privacy

    func testExportedLogHoldsNoMarginTextTranscriptAudioOrFeedURL() throws {
        let marginText = "PRIVATE-MARGIN-TEXT about my week"
        let subscription = FeedSubscription(
            id: "subscription-source-abc",
            source: SourceIdentity(id: "source-abc", kind: .podcastFeed, canonicalURL: "https://private.example/feed/SECRET-TOKEN", host: "private.example", title: "Members Only")
        )
        let entry = FeedEntry(
            id: "entry-abc", subscriptionId: subscription.id,
            canonicalURL: "https://private.example/episodes/1?auth=SECRET-EPISODE",
            audioURL: "https://cdn.private.example/ep1.mp3?key=SECRET-AUDIO",
            title: "Episode one", summary: "PRIVATE-SUMMARY", publishedAt: Self.time("2026-09-01T08:00:00Z")
        )
        let item = Item(
            id: "item-1", title: "Episode one", mediaType: "podcast", text: "PRIVATE-TRANSCRIPT words",
            externalReference: entry.canonicalURL, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///var/mobile/PRIVATE-AUDIO-PATH/ep1.mp3", durationMs: 1_800_000),
            sourceTitle: "Members Only", sourceURL: subscription.source.canonicalURL
        )
        let (source, signalItem) = try XCTUnwrap(ListeningSignalContext.context(for: item, subscriptions: [subscription], entries: [entry]))
        XCTAssertEqual(signalItem.id, entry.id, "an imported feed entry keeps its published id")
        XCTAssertEqual(signalItem.durationSeconds, 1_800)

        let recorder = makeRecorder()
        let published = ListeningSignalContext.item(for: entry, seenAt: Self.time("2026-09-01T09:00:00Z"))
        recorder.record(.itemPublished, source: ListeningSignalContext.source(for: subscription), item: published)
        recorder.noteListening(source: source, item: signalItem, at: Self.time("2026-09-02T19:00:00Z"))
        recorder.noteListening(source: source, item: signalItem, at: Self.time("2026-09-02T19:00:04Z"))
        recorder.record(.margin(kind: .written, length: marginText.count), source: source, item: signalItem)
        recorder.record(.margin(kind: .spoken, length: 12), source: source, item: signalItem)
        recorder.record(.share, source: source, item: signalItem)
        recorder.record(.export(packetId: "package-1", marginCount: 1), source: source, item: signalItem)
        recorder.recordPacketImport(packetId: "package-2", marginCount: 1, source: source, item: signalItem)
        recorder.record(.dismiss, source: source, item: published)
        recorder.record(.finish, source: source, item: signalItem)
        let exported = try XCTUnwrap(recorder.exportCopy(to: temporary.appendingPathComponent("share")))
        let text = try String(contentsOf: exported, encoding: .utf8)

        XCTAssertEqual(Set(ListeningSignalRecorder.read(exported).map(\.event.name)), [
            "item_published", "listened", "margin", "share", "export", "packet_import", "dismiss", "finish",
        ])
        for secret in ["PRIVATE", "SECRET", "private.example", "https://", "file://", ".mp3", "my week"] {
            XCTAssertFalse(text.contains(secret), "exported log contains \(secret)")
        }
    }

    // MARK: Context

    func testItemsMatchTheirFollowedSourceByURLOrTitleOnly() {
        let subscription = FeedSubscription(
            id: "subscription-source-1",
            source: SourceIdentity(id: "source-1", kind: .articleFeed, canonicalURL: "https://Example.com/feed/", host: "example.com", title: "Queue Notes")
        )
        let byURL = Item(id: "a", title: "A", mediaType: "article", text: nil, externalReference: nil, status: "ready", sourceURL: "https://example.com/feed", createdAt: Self.time("2026-09-01T08:00:00Z"))
        let byTitle = Item(id: "b", title: "B", mediaType: "article", text: nil, externalReference: nil, status: "ready", sourceTitle: "queue notes")
        let unfollowed = Item(id: "c", title: "C", mediaType: "pdf", text: nil, externalReference: nil, status: "ready", sourceTitle: "Somewhere else")
        let matched = ListeningSignalContext.context(for: byURL, subscriptions: [subscription], entries: [])
        XCTAssertEqual(matched?.source, ListeningSignalSource(id: "source-1", title: "Queue Notes", subscriptionKind: "article_feed", contentKind: "article"))
        XCTAssertEqual(matched?.item.id, "library-a")
        XCTAssertEqual(matched?.item.publishedAt, Self.time("2026-09-01T08:00:00Z"))
        XCTAssertEqual(ListeningSignalContext.context(for: byTitle, subscriptions: [subscription], entries: [])?.source.id, "source-1")
        let untitled = Item(id: "d", title: "  ", mediaType: "article", text: nil, externalReference: nil, status: "ready", sourceURL: "https://example.com/feed")
        XCTAssertEqual(ListeningSignalContext.context(for: untitled, subscriptions: [subscription], entries: [])?.item.title, "Untitled",
                       "D3's evaluator rejects a whole export over one empty title")
        let entry = FeedEntry(id: "entry-9", subscriptionId: subscription.id, canonicalURL: "https://example.com/9", title: "", publishedAt: nil)
        let published = ListeningSignalContext.item(for: entry, seenAt: Self.time("2026-09-03T08:00:00Z"), durationMs: 1_234_000)
        XCTAssertEqual(published, ListeningSignalItem(id: "entry-9", title: "Untitled", publishedAt: Self.time("2026-09-03T08:00:00Z"), durationSeconds: 1_234))
        XCTAssertNil(ListeningSignalContext.context(for: unfollowed, subscriptions: [subscription], entries: []))
    }

    // MARK: Helpers

    private func makeRecorder() -> ListeningSignalRecorder {
        ListeningSignalRecorder(fileURL: temporary.appendingPathComponent("i4-\(UUID().uuidString).jsonl"), flushDelay: 60)
    }

    private static let podcast = (
        ListeningSignalSource(id: "source-1", title: "Systems Weekly", subscriptionKind: "podcast_feed", contentKind: "podcast"),
        ListeningSignalItem(id: "entry-1", title: "Queues and clocks", publishedAt: time("2026-09-01T08:00:00Z"), durationSeconds: 900)
    )

    /// The scenario behind the published fixture: two followed sources, three items, every event.
    static func recordSampleScenario(_ recorder: ListeningSignalRecorder) {
        let weekly = ListeningSignalSource(id: "source-3f9a1c2b7d4e5f60a1b2c3d4", title: "Systems Weekly", subscriptionKind: "podcast_feed", contentKind: "podcast")
        let notes = ListeningSignalSource(id: "source-0b1c2d3e4f5a6b7c8d9e0f1a", title: "Queue Notes", subscriptionKind: "article_feed", contentKind: "article")
        let clocks = ListeningSignalItem(id: "entry-a1b2c3d4e5f6a7b8c9d0e1f2", title: "Queues and clocks", publishedAt: time("2026-09-01T06:00:00Z"), durationSeconds: 1_800)
        let backpressure = ListeningSignalItem(id: "entry-b2c3d4e5f6a7b8c9d0e1f2a3", title: "Backpressure, gently", publishedAt: time("2026-09-01T07:00:00Z"), durationSeconds: 2_400)
        let retries = ListeningSignalItem(id: "entry-c3d4e5f6a7b8c9d0e1f2a3b4", title: "Retries considered", publishedAt: time("2026-09-01T07:30:00Z"))
        recorder.record(.itemPublished, source: weekly, item: clocks, at: time("2026-09-01T08:00:00Z"))
        recorder.record(.itemPublished, source: weekly, item: backpressure, at: time("2026-09-01T08:00:00Z"))
        recorder.record(.itemPublished, source: notes, item: retries, at: time("2026-09-01T08:00:00Z"))
        let listenStart = time("2026-09-02T19:00:00Z")
        for tick in 0...240 { recorder.noteListening(source: weekly, item: clocks, at: listenStart.addingTimeInterval(Double(tick) * 0.5)) }
        recorder.endListening()
        recorder.record(.margin(kind: .spoken, length: 14), source: weekly, item: clocks, at: time("2026-09-02T19:05:00Z"))
        recorder.record(.margin(kind: .written, length: 184), source: weekly, item: clocks, at: time("2026-09-02T19:06:00Z"))
        recorder.record(.finish, source: weekly, item: clocks, at: time("2026-09-02T19:30:00Z"))
        recorder.record(.dismiss, source: notes, item: retries, at: time("2026-09-03T07:30:00Z"))
        recorder.record(.export(packetId: "package-5d0c8e1a-2b3f-4c5d-8e9f-0a1b2c3d4e5f", marginCount: 2), source: weekly, item: clocks, at: time("2026-09-03T20:00:00Z"))
        recorder.record(.share, source: weekly, item: clocks, at: time("2026-09-03T20:01:00Z"))
        recorder.recordPacketImport(packetId: "package-9e8d7c6b-5a4f-4e3d-9c2b-1a0f9e8d7c6b", marginCount: 3, source: weekly, item: backpressure, at: time("2026-09-04T09:00:00Z"))
        recorder.record(.margin(kind: .written, length: 61), source: weekly, item: backpressure, at: time("2026-09-04T21:00:00Z"))
    }

    static func time(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    static func path(_ relative: String) throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Contracts").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw CocoaError(.fileNoSuchFile) }
            root = parent
        }
        return root.appendingPathComponent(relative)
    }
}
