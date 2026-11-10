import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3793: iOS asks for Speech Recognition the first time something is transcribed, so a written Margin, which has
/// nothing to transcribe, must never reach the transcriber. Cole, 2026-11-10: the app should not request speech
/// recognition when a written Margin is submitted. A spoken Margin does reach it (that is where the question belongs),
/// which the second test pins so the first cannot pass by the transcriber being unwired.
final class WrittenMarginNeverTranscribedTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor"]
        ]
    )

    private var article: Item {
        Item(id: "item-article", title: "Article", mediaType: "text", text: "First sentence. Second sentence. Third sentence.", externalReference: nil, status: "ready")
    }

    private var directory: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "written-no-transcribe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        try store.saveItem(article)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Player: AudioPlaybackClient {
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws {}
        func play(targetId: String, from charOffset: Int) throws {}
        func currentCharOffset() -> Int? { 20 }
        func pause() throws {}
    }

    private final class RecordingTranscriber: TranscriptionClient {
        private(set) var scheduledIds: [String] = []
        func scheduleTranscription(interjection: Interjection) throws { scheduledIds.append(interjection.id) }
    }

    private func engine(transcriber: TranscriptionClient) throws -> SessionEngine {
        let engine = SessionEngine(profile: profile, repository: store, audio: Player(), transcriber: transcriber)
        _ = try engine.startSession(itemId: article.id)
        return engine
    }

    func testSavingAWrittenMarginNeverReachesTheTranscriber() throws {
        let transcriber = RecordingTranscriber()
        let engine = try engine(transcriber: transcriber)

        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A written note.")

        XCTAssertEqual(try store.loadInterjections(sessionId: capture.sessionId).count, 1)
        XCTAssertEqual(transcriber.scheduledIds, [], "a written Margin must not schedule transcription, which is what makes iOS ask for Speech Recognition")
    }

    func testASpokenMarginDoesReachTheTranscriber() throws {
        let transcriber = RecordingTranscriber()
        let engine = try engine(transcriber: transcriber)

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/margin-1.m4a")

        XCTAssertEqual(transcriber.scheduledIds.count, 1)
    }
}
