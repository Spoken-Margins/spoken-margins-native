import AVFoundation
import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class ListeningSignalsCoordinatorTests: XCTestCase {
    func testFollowingAnExistingSubscriptionRefreshesACachedMissingItemRelationship() async throws {
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
        signals.playbackProgress(itemId: item.id, status: .playing)
        _ = await signals.exportFileURL() // The same collector has cached a missing relationship.
        item.sourceURL = subscription.source.canonicalURL
        try store.saveItem(item)
        // Publishing the followed-source refresh must invalidate item relationships too, even
        // when the already-followed subscription itself did not change. The entry is a refresh
        // completion marker; it is not the listened item and cannot provide its context.
        try store.saveFeedEntry(FeedEntry(id: "refresh-marker", subscriptionId: subscription.id,
            canonicalURL: "https://publisher.example/other", title: "Other", state: .unseen))
        model.refreshFollowedSources(force: false)
        let deadline = Date().addingTimeInterval(5)
        while !model.followedSourceEntries.contains(where: { $0.id == "refresh-marker" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.followedSourceEntries.contains { $0.id == "refresh-marker" })
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

    func testAppCompletionRecordsTheSavedSpokenMargin() async throws {
        try await checkCompletion(compact: false)
    }

    func testCompactCompletionRecordsOnceAndRejectedRepeatAddsNothing() async throws {
        try await checkCompletion(compact: true)
    }

    private func checkCompletion(compact: Bool) async throws {
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
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: SavedFileRecordingClient(path: audioURL.path),
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
        if compact { model.dispatchGate2CompactCommand(.finishInterjection) }
        else { model.finishInterjection() }
        XCTAssertFalse(model.snapshot.isRecording)
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

private struct SavedFileRecordingClient: RecordingClient {
    let path: String
    func beginRecording() throws {}
    func finishRecording(audioRef: String?) throws -> String { path }
    func cancelRecording() throws {}
}
