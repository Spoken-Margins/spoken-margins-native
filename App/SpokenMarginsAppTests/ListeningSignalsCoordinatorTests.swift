import AVFoundation
import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class ListeningSignalsCoordinatorTests: XCTestCase {
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
