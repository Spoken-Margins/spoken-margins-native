import Foundation
import XCTest
import SQLite3
@testable import SessionKit
import SessionKitPersistence

final class MarginCaptureStartupTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
        "sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"],
        "timeline": ["media_time"],
        "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"]
    ])

    func testRecorderStartsBeforePersistenceWithSourcePaused() throws {
        let recorder = StartupRecorder()
        let player = StartupPlayer()
        let item = Item(id: "article", title: "Article", mediaType: "text", text: "First sentence. Second sentence.",
                        externalReference: nil, status: "ready")
        let repository = InMemorySessionRepository(items: [item.id: item], sessions: [:], interjections: [:])
        var checkingStartup = false
        let engine = SessionEngine(
            profile: profile,
            repository: repository, audio: player, recorder: recorder,
            now: {
                if checkingStartup {
                    XCTAssertTrue(recorder.started, "disk work must run while the microphone already captures first words")
                    XCTAssertFalse(player.playing, "the source must stay paused while recording")
                }
                return Date(timeIntervalSince1970: 5_000)
            }
        )
        _ = try engine.startSession(itemId: item.id)
        recorder.onStart = { XCTAssertFalse(player.playing) }
        checkingStartup = true
        XCTAssertTrue(try engine.beginInterjection().isRecording)
        checkingStartup = false
        XCTAssertEqual(engine.recordingAnchor?.startChar, 0)
        _ = try engine.finishInterjection(audioRef: nil)
        XCTAssertTrue(player.playing)
        XCTAssertEqual(try repository.loadInterjections(sessionId: XCTUnwrap(engine.snapshot.sessionId)).count, 1)
    }

    func testRouteSwitchCannotResetTheFrozenPodcastAnchor() throws {
        let item = Item(id: "podcast", title: "Podcast", mediaType: TargetType.transcriptBackedMedia.rawValue,
                        text: nil, externalReference: nil, status: "ready",
                        media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///podcast.mp3", durationMs: 600_000))
        let session = Session(id: "session", itemId: item.id, status: "in_progress", phase: .itemPlayback,
                              currentTargetType: .transcriptBackedMedia, currentTargetId: "file:///podcast.mp3",
                              position: Position(mediaTimeMs: 90_000), completionPercent: 15, playbackRate: 1)
        let repository = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [:])
        let player = StartupPlayer()
        let recorder = StartupRecorder()
        let engine = SessionEngine(profile: profile, repository: repository, audio: player, recorder: recorder)
        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.resumePlayback()
        player.mediaTimeMs = 93_500
        recorder.onStart = { player.mediaTimeMs = 0 }
        _ = try engine.beginInterjection()
        XCTAssertEqual(engine.recordingAnchor?.mediaTimeMs, 93_500)
        _ = try engine.cancelInterjection()
        XCTAssertEqual(player.mediaTimeMs, 93_500, "resume still uses the clock frozen before the route switch")
    }

    func testRealDatabaseWriteFailureAfterRecorderStartsReleasesItAndResumesSource() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "margin-start-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "article", title: "Article", mediaType: "text", text: "First sentence. Second sentence.",
                        externalReference: nil, status: "ready")
        try store.saveItem(item)
        let player = StartupPlayer()
        let recorder = StartupRecorder()
        let engine = SessionEngine(profile: profile, repository: store, audio: player, recorder: recorder)
        let sessionId = try XCTUnwrap(engine.startSession(itemId: item.id).sessionId)
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &lock), SQLITE_OK)
        defer { sqlite3_exec(lock, "ROLLBACK", nil, nil, nil); sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try engine.beginInterjection())
        XCTAssertEqual(recorder.starts, 1, "the microphone opened before waiting for the real SQLite write lock")
        XCTAssertEqual(recorder.cancels, 1, "a failed transaction releases the open microphone")
        XCTAssertFalse(recorder.started)
        XCTAssertFalse(engine.snapshot.isRecording)
        XCTAssertNil(engine.recordingAnchor)
        XCTAssertTrue(player.playing)
        XCTAssertTrue(engine.snapshot.status.isPlaybackActive)
        XCTAssertTrue(try store.loadInterjections(sessionId: sessionId).isEmpty)
    }

    func testEngineExportsSameTapAndFirstNonSilentReadingForOneCapture() throws {
        let item = Item(id: "article", title: "Article", mediaType: "text", text: "First sentence.",
                        externalReference: nil, status: "ready")
        let recorder = StartupRecorder()
        let engine = SessionEngine(profile: profile,
                                   repository: InMemorySessionRepository(items: [item.id: item], sessions: [:], interjections: [:]),
                                   audio: StartupPlayer(), recorder: recorder)
        _ = try engine.startSession(itemId: item.id)
        let request = MarginCaptureRequest()
        _ = try engine.beginInterjection(request: request)
        XCTAssertEqual(engine.recordingCaptureDiagnostics()["captureID"], request.id.uuidString)
        XCTAssertEqual(engine.recordingCaptureDiagnostics()["tapToFirstNonSilentObservedMs"], "not_observed")
        recorder.reading = .init(recorderRunning: true, capturedMs: 20, peakPowerDb: -35, inputRoute: "BluetoothHFP")
        _ = engine.recordingCaptureReading()
        let first = engine.recordingCaptureDiagnostics()
        XCTAssertNotEqual(first["tapToFirstNonSilentObservedMs"], "not_observed")
        XCTAssertEqual(first["firstNonSilentInputRoute"], "BluetoothHFP")
        _ = engine.recordingCaptureReading()
        XCTAssertEqual(engine.recordingCaptureDiagnostics(), first)
        _ = try engine.cancelInterjection()
    }
}

private final class StartupRecorder: RecordingClient {
    var started = false
    var starts = 0
    var cancels = 0
    var reading: RecordingCaptureReading?
    var onStart: () -> Void = {}
    func beginRecording() throws { starts += 1; onStart(); started = true }
    func cancelRecording() throws { cancels += 1; started = false }
    func finishRecording(audioRef: String?) throws -> String { started = false; return "interjections/test.m4a" }
    func captureReading() -> RecordingCaptureReading? { reading }
    func captureDiagnostics() -> [String: String] { ["inputs": "BluetoothHFP"] }
}

private final class StartupPlayer: AudioPlaybackClient {
    var playing = false
    var mediaTimeMs: Int?
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { playing = true }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws { playing = true; self.mediaTimeMs = mediaTimeMs }
    func pause() throws { playing = false }
    func currentCharOffset() -> Int? { 0 }
    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map { PlaybackPosition(mediaTimeMs: $0, durationMs: 600_000, playbackRate: 1, anchorConfidence: .mediaTime) }
    }
}
