import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

final class ListeningSignalRecorderTests: XCTestCase {
    private static func fixture() throws -> URL {
        try TestInputs.url(.contracts, "fixtures/listening-signals/i4-engagement-sample.jsonl")
    }
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
            try written.write(to: Self.fixture(), atomically: true, encoding: .utf8)
        }
        let fixture = try Self.fixture()
        let published = try String(contentsOf: fixture, encoding: .utf8)
        XCTAssertEqual(written, published, "the recorder's output changed; rerun with UPDATE_I4_FIXTURE=1 and update the I4 schema to match")
        XCTAssertEqual(try ListeningSignalRecorder.read(fixture).count, published.split(separator: "\n").count)
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

    /// #1048 (PERSIST-09): the test above only sees that no file exists yet, which is also true for a
    /// recorder whose calls wait for its queue (`queue.sync`), because nothing is written for 60 s
    /// either way. Playback reports on every progress tick, so a call that waits stalls playback.
    ///
    /// The queue is private, so this parks it on the one thing a test controls: a named pipe in place
    /// of the log file. Opening a pipe for writing blocks until something reads it, exactly as slow
    /// disk I/O would. While the queue is parked, every public call must still return at once.
    func testNoCallWaitsForTheRecordersQueue() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        XCTAssertEqual(mkfifo(log.path, 0o600), 0, "the queue is parked on a named pipe")
        let pipe = ParkedPipe(path: log.path)
        defer { _ = pipe.release() }
        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        let (source, item) = Self.podcast
        let start = Self.time("2026-09-02T19:00:00Z")

        // A call that waits for the queue is freed after three seconds, so it fails below instead of hanging the run.
        pipe.release(after: 3)

        func returnsAtOnce(_ name: String, _ call: () -> Void) {
            let began = Date()
            call()
            XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "\(name) waited for the recorder's queue")
        }

        // Closing a listening interval writes it at once, which opens the pipe and parks the queue.
        returnsAtOnce("noteListening") {
            recorder.noteListening(source: source, item: item, at: start)
            recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(2))
        }
        returnsAtOnce("endListening") { recorder.endListening() }
        // Control: a call that must wait for the queue does wait, so the queue really is parked.
        let waited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = recorder.writeError
            waited.signal()
        }
        XCTAssertEqual(waited.wait(timeout: .now() + 0.3), .timedOut, "the queue is not parked on the pipe, so this test proves nothing")

        returnsAtOnce("record") { recorder.record(.finish, source: source, item: item, at: start) }
        returnsAtOnce("noteListening") {
            recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(10))
            recorder.noteListening(source: source, item: item, at: start.addingTimeInterval(12))
        }
        returnsAtOnce("endListening") { recorder.endListening() }
        returnsAtOnce("recordPacketImport") {
            recorder.recordPacketImport(packetId: "package-1", marginCount: 1, source: source, item: item, at: start)
        }

        // Freed with nothing to read, the queue's first write fails (a pipe cannot seek) and keeps the
        // rows for the next write, which creates a plain file; if a platform lets it write into the
        // pipe instead, those rows are in what the pipe held. Either way they are all accounted for.
        let leftInPipe = pipe.release()
        let inFile = recorder.signals()
        let copy = temporary.appendingPathComponent("from-pipe.jsonl")
        try leftInPipe.write(to: copy)
        XCTAssertEqual((ListeningSignalRecorder.read(copy) + inFile).map(\.event), [
            .listened(seconds: 2),
            .finish,
            .listened(seconds: 2),
            .packetImport(packetId: "package-1", fromOther: true, marginCount: 1),
        ], "everything called while the queue was parked is written once it is free")
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
        XCTAssertEqual(Self.signalsOnceWritten(log).map(\.event), [.share])
    }

    /// #890: the recorder creates an empty log before it appends the first row, so the file existing
    /// is not the row being written. The wait is for a readable row; a missing, empty or half-written
    /// log keeps it waiting, and a flush that never runs ends it empty, not early with a stale read.
    func testWaitingForASignalIgnoresMissingEmptyAndPartialLogs() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let line = try Self.encodedShareRow()
        XCTAssertTrue(Self.signalsOnceWritten(log, timeout: 0.2).isEmpty, "missing")
        try Data().write(to: log)
        XCTAssertTrue(Self.signalsOnceWritten(log, timeout: 0.2).isEmpty, "empty")
        try line.prefix(line.count / 2).write(to: log)
        XCTAssertTrue(Self.signalsOnceWritten(log, timeout: 0.2).isEmpty, "partial")
        try line.write(to: log)
        XCTAssertEqual(Self.signalsOnceWritten(log, timeout: 0.2).map(\.event), [.share], "complete")
    }

    func testWaitingForASignalOutlastsAnEmptyThenPartialLog() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let line = try Self.encodedShareRow()
        try Data().write(to: log)
        XCTAssertTrue(ListeningSignalRecorder.read(log).isEmpty, "the file exists but holds no row: the old wait would have stopped here")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { try? line.prefix(line.count / 2).write(to: log) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { try? line.write(to: log) }
        XCTAssertEqual(Self.signalsOnceWritten(log).map(\.event), [.share])
    }

    func testWaitingForAScheduledFlushThatNeverRunsComesBackEmpty() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        let (source, item) = Self.podcast
        recorder.record(.share, source: source, item: item)
        XCTAssertTrue(Self.signalsOnceWritten(log, timeout: 0.3).isEmpty,
                      "a recorder whose scheduled write is disabled or late fails the wait")
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

    /// #867: an export from an item without a followed source logs no row, so the packet id is
    /// noted in its own small file beside the log, and a later launch still knows it is ours.
    func testANotedExportIsRememberedAcrossLaunchesWithoutAnyLogRow() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let (source, item) = Self.podcast
        let first = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        first.noteExportedPacket("package-mine")
        _ = first.writeError // waits for the queue, without flushing
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "noting an export writes no log row")

        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        recorder.recordPacketImport(packetId: "package-mine", marginCount: 2, source: source, item: item)
        recorder.recordPacketImport(packetId: "package-theirs", marginCount: 1, source: source, item: item)
        XCTAssertEqual(recorder.signals().map(\.event), [
            .packetImport(packetId: "package-mine", fromOther: false, marginCount: 2),
            .packetImport(packetId: "package-theirs", fromOther: true, marginCount: 1),
        ])
    }

    func testAnUnreadableExportedPacketsFileFallsBackToTheLogAndIsRewritten() throws {
        let log = temporary.appendingPathComponent("i4.jsonl")
        let noted = temporary.appendingPathComponent("exported-packets.json")
        let (source, item) = Self.podcast
        let first = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        first.record(.export(packetId: "package-logged", marginCount: 1), source: source, item: item)
        first.flush()
        try Data("not json".utf8).write(to: noted)

        let recorder = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        recorder.recordPacketImport(packetId: "package-logged", marginCount: 1, source: source, item: item)
        recorder.noteExportedPacket("package-noted")
        _ = recorder.writeError
        XCTAssertEqual(recorder.signals().map(\.event).last, .packetImport(packetId: "package-logged", fromOther: false, marginCount: 1))

        let relaunched = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        relaunched.recordPacketImport(packetId: "package-noted", marginCount: 1, source: source, item: item)
        XCTAssertEqual(relaunched.signals().map(\.event).last, .packetImport(packetId: "package-noted", fromOther: false, marginCount: 1))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: noted)), ["package-logged", "package-noted"])
    }

    /// Unfollowing deletes a feed's unimported entries but keeps the log; following it again
    /// must not publish the same entries twice, in the same launch or a later one.
    func testAnEntryIsPublishedOnceEvenAfterRefollowing() {
        let log = temporary.appendingPathComponent("i4-\(UUID().uuidString).jsonl")
        let (source, item) = Self.podcast
        let first = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        first.record(.itemPublished, source: source, item: item)
        first.record(.itemPublished, source: source, item: item)
        first.flush()
        let later = ListeningSignalRecorder(fileURL: log, flushDelay: 60)
        later.record(.itemPublished, source: source, item: item)
        var other = item
        other.id = "entry-2"
        later.record(.itemPublished, source: source, item: other)
        XCTAssertEqual(later.signals().map { $0.item?.id }, ["entry-1", "entry-2"])
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

    func testImportedArticleMatchesItsEntryWithoutSourceMetadata() throws {
        let subscription = FeedSubscription(id: "subscription", source: SourceIdentity(
            id: "source", kind: .articleFeed, canonicalURL: "https://example.com/feed",
            host: "example.com", title: "Notes"))
        let entry = FeedEntry(id: "entry", subscriptionId: subscription.id,
                              canonicalURL: "https://example.com/posts/1", title: "One", publishedAt: Self.time("2026-09-01T08:00:00Z"))
        let item = Item(id: "imported", title: "One", mediaType: "article", text: "Words",
                        externalReference: entry.canonicalURL, status: "ready")
        let context = try XCTUnwrap(ListeningSignalContext.context(for: item, subscriptions: [subscription], entries: [entry]))
        XCTAssertEqual(context.source.id, "source")
        XCTAssertEqual(context.item.id, entry.id)
        // An exact entry relationship wins over unrelated or stale display metadata.
        var stale = item
        stale.sourceTitle = "Other source"
        let other = FeedSubscription(id: "other", source: SourceIdentity(id: "other-source", kind: .articleFeed,
            canonicalURL: "https://other.example/feed", host: "other.example", title: "Other source"))
        XCTAssertEqual(ListeningSignalContext.context(for: stale, subscriptions: [other, subscription], entries: [entry])?.source.id, "source")
        XCTAssertNil(ListeningSignalContext.context(for: item, subscriptions: [other], entries: [entry]),
                     "an orphaned feed entry must not manufacture a followed source")
    }

    func testEpisodesSharingAWebpageMatchByAudioOrGUIDNotByPageOrder() throws {
        let subscription = FeedSubscription(id: "subscription", source: SourceIdentity(
            id: "source", kind: .podcastFeed, canonicalURL: "https://show.example/feed",
            host: "show.example", title: "Show"))
        let page = "https://show.example/episodes"
        let first = FeedEntry(id: "entry-a", subscriptionId: subscription.id, canonicalURL: page,
                              audioURL: "https://cdn.show.example/a.mp3", title: "A", episodeGUID: "guid-a")
        let second = FeedEntry(id: "entry-b", subscriptionId: subscription.id, canonicalURL: page,
                               audioURL: "https://cdn.show.example/b.mp3", title: "B", episodeGUID: "guid-b")
        let entries = [first, second]

        let streamed = Item(id: "streamed", title: "B", mediaType: "podcast", text: "",
                            externalReference: page, status: "ready",
                            media: ItemMedia(sourceType: .remoteStream, url: second.audioURL!))
        XCTAssertEqual(ListeningSignalContext.context(for: streamed, subscriptions: [subscription], entries: entries)?.item.id,
                       second.id, "the exact audio URL wins over a webpage another episode shares")

        var downloaded = Item(id: "downloaded", title: "B", mediaType: "podcast", text: "",
                              externalReference: page, status: "ready",
                              media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///var/mobile/b.mp3"),
                              sourceURL: subscription.source.canonicalURL)
        downloaded.episodeGUID = "guid-b"
        XCTAssertEqual(ListeningSignalContext.context(for: downloaded, subscriptions: [subscription], entries: entries)?.item.id,
                       second.id, "the episode GUID wins once the audio is a local file")

        downloaded.episodeGUID = nil
        let ambiguous = try XCTUnwrap(ListeningSignalContext.context(for: downloaded, subscriptions: [subscription], entries: entries))
        XCTAssertEqual(ambiguous.item.id, "library-downloaded", "a webpage two episodes share names neither")
        XCTAssertEqual(ambiguous.source.id, "source")
    }

    func testEpisodeGUIDMatchesOnlyWithinTheItemsOwnSource() {
        let feedA = FeedSubscription(id: "subscription-a", source: SourceIdentity(
            id: "source-a", kind: .podcastFeed, canonicalURL: "https://a.example/feed", host: "a.example", title: "A Show"))
        let feedB = FeedSubscription(id: "subscription-b", source: SourceIdentity(
            id: "source-b", kind: .podcastFeed, canonicalURL: "https://b.example/feed", host: "b.example", title: "B Show"))
        let entryA = FeedEntry(id: "entry-a", subscriptionId: feedA.id, canonicalURL: "https://a.example/1",
                               audioURL: "https://cdn.a.example/1.mp3", title: "A one", episodeGUID: "episode-1")
        let entryB = FeedEntry(id: "entry-b", subscriptionId: feedB.id, canonicalURL: "https://b.example/1",
                               audioURL: "https://cdn.b.example/1.mp3", title: "B one", episodeGUID: "episode-1")
        var item = Item(id: "from-a", title: "A one", mediaType: "podcast", text: "",
                        externalReference: entryA.canonicalURL, status: "ready",
                        media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///var/mobile/a1.mp3"),
                        sourceURL: feedA.source.canonicalURL)
        item.episodeGUID = "episode-1"

        let followingBoth = ListeningSignalContext.context(for: item, subscriptions: [feedB, feedA], entries: [entryB, entryA])
        XCTAssertEqual(followingBoth?.source.id, "source-a")
        XCTAssertEqual(followingBoth?.item.id, "entry-a", "the GUID matches inside the item's own feed")

        XCTAssertNil(ListeningSignalContext.context(for: item, subscriptions: [feedB], entries: [entryB]),
                     "after unfollowing A, a shared GUID alone must not file A's episode under B")
    }

    func testASharedSourceTitleDoesNotPickTheFeedAnEpisodeIsMatchedIn() {
        let feedA = FeedSubscription(id: "subscription-a", source: SourceIdentity(
            id: "source-a", kind: .podcastFeed, canonicalURL: "https://a.example/feed", host: "a.example", title: "The Show"))
        let feedB = FeedSubscription(id: "subscription-b", source: SourceIdentity(
            id: "source-b", kind: .podcastFeed, canonicalURL: "https://b.example/feed", host: "b.example", title: "The Show"))
        let entryA = FeedEntry(id: "entry-a", subscriptionId: feedA.id, canonicalURL: "https://a.example/1",
                               audioURL: "https://cdn.a.example/1.mp3", title: "A one", episodeGUID: "episode-1")
        let entryB = FeedEntry(id: "entry-b", subscriptionId: feedB.id, canonicalURL: "https://b.example/1",
                               audioURL: "https://cdn.b.example/1.mp3", title: "B one", episodeGUID: "episode-1")
        var item = Item(id: "from-b", title: "B one", mediaType: "podcast", text: "",
                        externalReference: entryB.canonicalURL, status: "ready",
                        media: ItemMedia(sourceType: .nativeMediaFile, url: entryB.audioURL),
                        sourceTitle: "The Show")
        item.episodeGUID = "episode-1"

        let context = ListeningSignalContext.context(for: item, subscriptions: [feedA, feedB], entries: [entryA, entryB])
        XCTAssertEqual(context?.source.id, "source-b", "two followed sources share the title, so the URLs decide")
        XCTAssertEqual(context?.item.id, "entry-b")
    }

    func testOnlyALiveSessionFinishingForTheFirstTimeNamesAFinishedItem() {
        var playing = SessionSnapshot()
        playing.sessionId = "session"
        playing.itemId = "item"
        playing.phase = .itemPlayback
        var finished = playing
        finished.phase = .finished
        var recording = playing
        recording.phase = .recordingInterjection

        var tracker = ListeningSignalFinishTracker()
        XCTAssertEqual(tracker.finishedItem(from: playing, to: finished), "item",
                       "playback reaching the end or a skip past it")
        XCTAssertNil(tracker.finishedItem(from: finished, to: finished), "later ticks add nothing")
        XCTAssertNil(tracker.finishedItem(from: recording, to: finished), "a recap Margin saved or canceled afterwards")

        var reopened = ListeningSignalFinishTracker()
        XCTAssertNil(reopened.finishedItem(from: SessionSnapshot(), to: finished), "opening an already finished session")
        XCTAssertNil(reopened.finishedItem(from: recording, to: finished),
                     "a recap Margin on a session that was already finished when opened")

        var endOfItemMargin = ListeningSignalFinishTracker()
        XCTAssertEqual(endOfItemMargin.finishedItem(from: recording, to: finished), "item",
                       "a Margin recorded at the very end, then the session finishes for the first time")

        var other = ListeningSignalFinishTracker()
        var idle = playing
        idle.phase = .idle
        XCTAssertNil(other.finishedItem(from: idle, to: finished), "loading a finished session")
        var otherSession = playing
        otherSession.sessionId = "earlier"
        var switched = ListeningSignalFinishTracker()
        XCTAssertNil(switched.finishedItem(from: otherSession, to: finished))
    }

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

    func testValidUnfollowedSourceURLCannotBorrowASameTitleSubscription() {
        let subscription = FeedSubscription(id: "followed", source: SourceIdentity(id: "source-b", kind: .articleFeed,
            canonicalURL: "https://b.example/feed", host: "b.example", title: "Daily News"))
        let item = Item(id: "a", title: "A", mediaType: "article", text: "Words", externalReference: nil,
            status: "ready", sourceTitle: "Daily News", sourceURL: "https://a.example/feed")
        XCTAssertNil(ListeningSignalContext.context(for: item, subscriptions: [subscription], entries: []))
    }

    /// An older article imported through Safari has no source metadata; a followed site feed still names its source.
    func testAnArticleOnAFollowedSiteMatchesItsSiteFeedWithoutSourceMetadata() {
        let subscription = FeedSubscription(id: "followed", source: SourceIdentity(id: "publisher", kind: .articleFeed,
            canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Publisher"))
        let older = Item(id: "older", title: "Older", mediaType: "article", text: "Words",
            externalReference: "https://www.publisher.example/p/older", status: "ready")
        let context = ListeningSignalContext.context(for: older, subscriptions: [subscription], entries: [])
        XCTAssertEqual(context?.source.id, "publisher")
        XCTAssertEqual(context?.item.id, "library-older")

        let elsewhere = Item(id: "elsewhere", title: "Older", mediaType: "article", text: "Words",
            externalReference: "https://www.publisher.example/p/older", status: "ready", sourceURL: "https://other.example/feed")
        XCTAssertNil(ListeningSignalContext.context(for: elsewhere, subscriptions: [subscription], entries: []),
                     "an item's own source link still decides on its own")
    }

    // MARK: Helpers

    private func makeRecorder() -> ListeningSignalRecorder {
        ListeningSignalRecorder(fileURL: temporary.appendingPathComponent("i4-\(UUID().uuidString).jsonl"), flushDelay: 60)
    }

    /// Polls until at least `count` rows are readable in `log` or `timeout` passes, then returns what
    /// is readable. File existence is not enough (#890); `read` skips a partly written line.
    private static func signalsOnceWritten(_ log: URL, count: Int = 1, timeout: TimeInterval = 5) -> [ListeningSignal] {
        let deadline = Date().addingTimeInterval(timeout)
        var signals = ListeningSignalRecorder.read(log)
        while signals.count < count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            signals = ListeningSignalRecorder.read(log)
        }
        return signals
    }

    /// One complete `share` row, newline included, encoded the way the recorder writes it.
    private static func encodedShareRow() throws -> Data {
        let (source, item) = podcast
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(ListeningSignal(event: .share, at: time("2026-09-02T19:00:00Z"), source: source, item: item))
        data.append(UInt8(ascii: "\n"))
        return data
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
}

/// A named pipe at the recorder's log path. The recorder's queue parks opening it for writing until
/// something opens it for reading, which `release()` does, after moving the pipe out of the log's
/// path so that nothing the queue does next can wait on it again.
private final class ParkedPipe: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var released = false
    private var leftovers = Data()

    init(path: String) { self.path = path }

    func release(after seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { _ = self.release() }
    }

    /// Frees the queue, and returns what it wrote into the pipe (nothing, when its first write failed).
    @discardableResult
    func release() -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return leftovers }
        released = true
        let spare = path + ".released"
        guard rename(path, spare) == 0 else { return leftovers }
        let reader = open(spare, O_RDONLY | O_NONBLOCK)
        unlink(spare)
        guard reader >= 0 else { return leftovers }
        // Give the freed queue a moment to write or fail, then take what reached the pipe.
        Thread.sleep(forTimeInterval: 0.2)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(reader, &buffer, buffer.count)
            if count <= 0 { break }
            leftovers.append(contentsOf: buffer[0..<count])
        }
        close(reader)
        return leftovers
    }
}
