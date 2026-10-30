import AVFoundation
import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class ListeningSignalsCoordinatorTests: XCTestCase {
    /// #1340: the refresh is the test's own, awaited, after the model's launch refresh has landed.
    /// It used to start an unstructured refresh that a still-running launch refresh could swallow,
    /// and the swallowed run left the cached "no source" context in place. Since the collector keys
    /// on the item's own source fields, this case checks the refresh path still ends in a correct
    /// export; the no-refresh case below is the one that guards the collector.
    func testFollowingAnExistingSubscriptionRefreshesACachedMissingItemRelationship() async throws {
        try await checkAnItemThatGainsAFollowedSource(refreshing: true)
    }

    /// The collector alone: the item gains the followed source's URL while the subscriptions stay as
    /// they were, and nothing refreshes. This is the case that fails without the collector keying
    /// its cache on the item's own source fields (#1340).
    func testAnItemThatGainsAFollowedSourceIsCreditedWithoutAnyRefresh() async throws {
        try await checkAnItemThatGainsAFollowedSource(refreshing: false)
    }

    private func checkAnItemThatGainsAFollowedSource(refreshing: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("existing-follow.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: database.path)
        var item = try store.loadItem(id: "item-pill")
        item.externalReference = nil; item.sourceURL = nil; item.sourceTitle = nil
        try store.saveItem(item)
        let subscription = FeedSubscription(id: "existing", source: SourceIdentity(id: "publication", kind: .articleFeed,
            canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Publisher"), lastRefreshAt: Date())
        try store.saveFeedSubscription(subscription)
        let originalSubscriptions = try store.loadFeedSubscriptions()
        let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        let signals = ListeningSignalsCoordinator(recorder: recorder, repository: { store })
        model.listeningSignals = signals
        // The model's launch refresh reassigns feedSubscriptions, which ends listening. Let it
        // land before the window under test, so it can't end the interval half way through.
        let launchDeadline = Date().addingTimeInterval(10)
        while model.diagnostics["followedSourceCount"] == nil || model.isRefreshingFollowedSources, Date() < launchDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.diagnostics["followedSourceCount"], "the launch refresh landed before playback")
        signals.playbackProgress(itemId: item.id, status: .playing)
        _ = await signals.exportFileURL() // The same collector has cached a missing relationship.
        item.sourceURL = subscription.source.canonicalURL
        try store.saveItem(item)
        if refreshing {
            // Publishing the followed-source refresh must invalidate item relationships too, even
            // when the already-followed subscription itself did not change. The entry is a refresh
            // completion marker; it is not the listened item and cannot provide its context.
            try store.saveFeedEntry(FeedEntry(id: "refresh-marker", subscriptionId: subscription.id,
                canonicalURL: "https://publisher.example/other", title: "Other", state: .unseen))
            XCTAssertFalse(model.isRefreshingFollowedSources, "a refresh already running would swallow this one")
            await model.performFollowedSourceRefresh(force: false)
            XCTAssertTrue(model.followedSourceEntries.contains { $0.id == "refresh-marker" })
        }
        XCTAssertEqual(try store.loadFeedSubscriptions(), originalSubscriptions)
        signals.playbackProgress(itemId: item.id, status: .playing)
        try await Task.sleep(for: .milliseconds(1_100))
        signals.playbackProgress(itemId: item.id, status: .playing)
        signals.endListening()
        let exported = await signals.exportFileURL()
        let rows = exported.map(ListeningSignalRecorder.read) ?? []
        XCTAssertEqual(rows.map { $0.source.id }, [subscription.source.id])
        guard case .listened(let seconds) = try XCTUnwrap(rows.first?.event) else {
            return XCTFail("confirmed playing after relationship refresh must be exported")
        }
        XCTAssertGreaterThanOrEqual(seconds, 1, "the recorder rounds real elapsed time to tenths")
        model.endSession()
    }

    /// The model's own playback ticker turns confirmed playing into listening time (#1129, PERSIST-06).
    /// ListeningSignalMergeIntegrationTests checks the source text; this drives Gate1AppModel and
    /// reads the rows. Nothing here calls the coordinator's playbackProgress: only the tick does.
    func testThePlaybackTickerRecordsListeningTimeForAFollowedItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("ticker.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: database.path)
        let subscription = FeedSubscription(id: "followed", source: SourceIdentity(id: "publication", kind: .articleFeed,
            canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Publisher"), lastRefreshAt: Date())
        try store.saveFeedSubscription(subscription)
        var item = try store.loadItem(id: "item-pill")
        item.externalReference = nil
        item.sourceURL = subscription.source.canonicalURL
        try store.saveItem(item)
        let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        let signals = ListeningSignalsCoordinator(recorder: recorder, repository: { store })
        model.listeningSignals = signals

        // The launch refresh of followed sources reassigns feedSubscriptions, which ends the
        // listening interval; let it land before playback so it doesn't split the window.
        let deadline = Date().addingTimeInterval(10)
        while model.diagnostics["followedSourceCount"] != "1" || model.isRefreshingFollowedSources, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.diagnostics["followedSourceCount"], "1", "the launch refresh saw the followed source")

        model.startItem(id: "item-pill")
        XCTAssertEqual(model.snapshot.status, .playing)
        try await Task.sleep(for: .milliseconds(3_600)) // about seven 500 ms ticks
        XCTAssertEqual(model.snapshot.status, .playing, "every tick saw confirmed playing")

        let exported = await signals.exportFileURL()
        let rows = exported.map(ListeningSignalRecorder.read) ?? []
        XCTAssertFalse(rows.isEmpty, "the ticker recorded no listening time")
        XCTAssertEqual(Set(rows.map { $0.source.id }), [subscription.source.id], "rows are for the followed source")
        // A late second refresh could still split the interval in two, so add the pieces up.
        let seconds = rows.reduce(0.0) { total, row in
            guard case .listened(let seconds) = row.event else { XCTFail("unexpected row \(row.event.name)"); return total }
            return total + seconds
        }
        XCTAssertGreaterThanOrEqual(seconds, 1, "the first tick to the last spans about 3 s")
        model.endSession()
    }

    func testShareCreditsTheItemThePacketWasBuiltForNotTheSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("share.sqlite").path)
        let subscription = FeedSubscription(id: "followed", source: SourceIdentity(id: "publication", kind: .articleFeed,
            canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Publisher"))
        try store.saveFeedSubscription(subscription)
        for id in ["a", "b"] {
            try store.saveItem(Item(id: id, title: id.uppercased(), mediaType: "article", text: "Words",
                externalReference: nil, status: "ready", sourceURL: subscription.source.canonicalURL))
        }
        let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        let signals = ListeningSignalsCoordinator(recorder: recorder, repository: { store })
        let packetB = root.appendingPathComponent("b.spokenmargins")
        signals.export(itemId: "b", packetId: "package-b", marginCount: 1, packetURL: packetB)
        // Item A may be selected by the time B's share sheet completes; the packet still names B.
        signals.share(packetURL: packetB)
        signals.share(packetURL: root.appendingPathComponent("never-built.spokenmargins"))
        let exported = await signals.exportFileURL()
        let rows = exported.map(ListeningSignalRecorder.read) ?? []
        XCTAssertEqual(rows.map { "\($0.event.name):\($0.item?.id ?? "-")" }, ["export:library-b", "share:library-b"])
    }

    /// A finish that saves its Margin and then fails to resume playback reaches the hook from the
    /// success path's defer and the failure path; the Margin counts once. Margin ids repeat across
    /// sessions (`ij-001`), so another session's first Margin still counts.
    func testASpokenMarginReachingTheHookTwiceCountsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("margin.sqlite").path)
        let subscription = FeedSubscription(id: "followed", source: SourceIdentity(id: "publication", kind: .articleFeed,
            canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Publisher"))
        try store.saveFeedSubscription(subscription)
        try store.saveItem(Item(id: "a", title: "A", mediaType: "article", text: "Words",
            externalReference: nil, status: "ready", sourceURL: subscription.source.canonicalURL))
        let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        let signals = ListeningSignalsCoordinator(recorder: recorder, repository: { store })
        for (session, id) in [("session-a", "ij-001"), ("session-a", "ij-001"), ("session-a", "ij-002"), ("session-b", "ij-001")] {
            signals.spokenMargin(sessionId: session, interjectionId: id, itemId: "a", audioURL: nil)
        }
        let exported = await signals.exportFileURL()
        let rows = exported.map(ListeningSignalRecorder.read) ?? []
        XCTAssertEqual(rows.map(\.event), Array(repeating: .margin(kind: .spoken, length: 0), count: 3))
    }

    func testAppCompletionRecordsTheSavedSpokenMargin() async throws {
        try await checkCompletion(compact: false)
    }

    func testCompactCompletionRecordsOnceAndRejectedRepeatAddsNothing() async throws {
        try await checkCompletion(compact: true)
    }

    /// #771 audit P3: a Margin a call cut short is a spoken Margin like any other, so it counts once.
    func testAMarginCutShortByACallRecordsTheSpokenSignal() async throws {
        try await checkCompletion(compact: false, interruptedByACall: true)
    }

    private func checkCompletion(compact: Bool, interruptedByACall: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("margin.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: 48_000)
        try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: buffer)
        let database = root.appendingPathComponent("library.sqlite")
        let savedFileRecorder = SavedFileRecordingClient(path: audioURL.path)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: savedFileRecorder,
            interjectionTranscriptionHandler: { _ in "A saved Margin." }, databaseURLOverride: database)
        model.resetAndSeed()
        model.declineCurrentTerms()
        let repository = try SQLiteSessionStore(path: database.path)
        var item = try repository.loadItem(id: "item-pill")
        item.externalReference = "https://example.com/post"
        item.sourceURL = nil
        item.sourceTitle = nil
        try repository.saveItem(item)
        try repository.saveFeedSubscription(FeedSubscription(id: "subscription", source: SourceIdentity(
            id: "source", kind: .articleFeed, canonicalURL: "https://example.com/feed", host: "example.com", title: "Notes")))
        try repository.saveFeedEntry(FeedEntry(id: "entry", subscriptionId: "subscription",
            canonicalURL: item.externalReference!, title: item.title, publishedAt: Date()))
        let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        let coordinator = ListeningSignalsCoordinator(recorder: recorder, repository: { repository })
        model.listeningSignals = coordinator
        model.startItem(id: item.id)
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        if interruptedByACall {
            savedFileRecorder.onInterruption?(.interruptionBegan, 5)
            for _ in 0..<50 where model.snapshot.isRecording { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(model.diagnostics["lastMarginCutShort"])
        } else if compact { model.dispatchGate2CompactCommand(.finishInterjection) }
        else { model.finishInterjection() }
        XCTAssertFalse(model.snapshot.isRecording)
        await model.settleItemReload() // the item detail reloads off the main thread after a save (#2967)
        XCTAssertEqual(model.selectedItem.interjections.count, 1)
        let exported = await coordinator.exportFileURL()
        XCTAssertNotNil(exported, "the first explicit export includes the saved spoken Margin")
        let margins = recorder.signals().filter { $0.event.name == "margin" }
        XCTAssertEqual(margins.map(\.event), [.margin(kind: .spoken, length: 1)])
        XCTAssertEqual(margins.first?.item?.id, "entry")
        XCTAssertEqual(margins.first?.source.id, "source")
        if compact {
            model.dispatchGate2CompactCommand(.finishInterjection)
            _ = await coordinator.exportFileURL()
            XCTAssertEqual(recorder.signals().filter { $0.event.name == "margin" }.count, 1)
        }
        model.endSession()
    }
}

private final class SavedFileRecordingClient: RecordingClient, RecordingInterruptionReporting, @unchecked Sendable {
    let path: String
    var onInterruption: (@Sendable (_ event: MarginRecordingInterruptionEvent, _ recordedSeconds: TimeInterval?) -> Void)?
    init(path: String) { self.path = path }
    func beginRecording() throws {}
    func finishRecording(audioRef: String?) throws -> String { path }
    func cancelRecording() throws {}
}
