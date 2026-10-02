import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #651: closing the source must also relinquish inline Margin playback, without
/// relying on a progress tick or a different item ID. These tests check lifecycle
/// ordering with a real engine/store; they do not reproduce AVAudioPlayer output.
final class SessionCloseInlinePlaybackTests: XCTestCase {
    func testCloseCancelsInlineMarginBeforeStoppingSourceAndContinuingSameEpisode() throws {
        try withEpisode { engine, audio, store in
            let sessionID = try XCTUnwrap(engine.snapshot.sessionId)
            _ = try engine.pause() // The source is paused while a Margin has the floor.
            var moment: MarginMomentSequence? = MarginMomentSequence(
                itemId: "episode", target: .init(marginId: "margin", mediaTimeMs: 12_000), otherMargins: []
            )
            XCTAssertNotNil(moment?.jumpToTarget())
            audio.onStop = { XCTAssertNil(moment, "inline ownership must end before source teardown") }
            var cancellations = 0

            let closed = try engine.endSession(stoppingInlinePlayback: {
                cancellations += 1
                moment = nil // The app supplies endMarginMoment (cancel voice + clear UI).
            })

            XCTAssertNil(moment, "same-item Continue must not retain the old Margin")
            XCTAssertEqual(cancellations, 1)
            XCTAssertNil(closed.sessionId)
            XCTAssertEqual(audio.starts, 1, "cancelling a Margin must not resume the source")
            let saved = try XCTUnwrap(store.loadSession(id: sessionID))
            XCTAssertEqual(saved.position.mediaTimeMs, 12_000)
            XCTAssertEqual(saved.status, "in_progress")

            _ = try engine.inspectSession(sessionId: saved.id)
            XCTAssertEqual(try engine.resumePlayback().status, .playing)
            XCTAssertEqual(audio.mediaTimeMs, 12_000)
            audio.advance(by: 500)
            XCTAssertEqual(try engine.syncPlaybackProgress().currentMediaTimeMs, 12_500)
            XCTAssertEqual(try engine.pause().status, .paused)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertEqual(audio.starts, 2, "the next source pause must not start any playback")
        }
    }

    func testCloseCancelsInlinePlaybackWhenSourceIsPlayingToo() throws {
        try withEpisode { engine, audio, _ in
            var cancellations = 0
            audio.onStop = { XCTAssertEqual(cancellations, 1) }
            _ = try engine.endSession(stoppingInlinePlayback: { cancellations += 1 })
            XCTAssertEqual(cancellations, 1, "cleanup is unconditional, regardless of transport state")
            XCTAssertFalse(audio.isPlaying)
            XCTAssertEqual(audio.starts, 1)
        }
    }

    func testCloseCancelsLeadInBeforeStartingAnotherItem() throws {
        try withEpisode { engine, audio, store in
            var moment: MarginMomentSequence? = MarginMomentSequence(
                itemId: "episode", target: .init(marginId: "later", mediaTimeMs: 40_000), otherMargins: []
            )
            _ = try engine.endSession(stoppingInlinePlayback: { moment = nil })
            try store.saveItem(Self.episode(id: "another-episode"))
            let started = try engine.startSession(itemId: "another-episode")
            XCTAssertNil(moment)
            XCTAssertEqual(started.itemId, "another-episode")
            XCTAssertEqual(started.status, .playing)
            XCTAssertEqual(audio.starts, 2)
        }
    }

    func testCleanupStillRunsIfStoppingSourceThrows() throws {
        try withEpisode { engine, audio, _ in
            audio.stopError = SessionKitError.invalidCommandForState("test_stop_failure")
            var cancellations = 0
            XCTAssertThrowsError(try engine.endSession(stoppingInlinePlayback: { cancellations += 1 }))
            XCTAssertEqual(cancellations, 1, "a teardown failure must not leave the old voice resumable")
            XCTAssertEqual(audio.starts, 1)
        }
    }

    func testCloseWithoutInlinePlaybackKeepsExistingAPIAndSavedPosition() throws {
        try withEpisode { engine, audio, store in
            let sessionID = try XCTUnwrap(engine.snapshot.sessionId)
            XCTAssertNil(try engine.endSession().sessionId)
            XCTAssertEqual(try store.loadSession(id: sessionID)?.position.mediaTimeMs, 12_000)
            XCTAssertFalse(audio.isPlaying)
        }
    }

    private static func episode(id: String = "episode") -> Item {
        Item(
            id: id, title: id, mediaType: "audio", text: nil, externalReference: nil, status: "ready",
            media: .init(sourceType: .nativeMediaFile, url: "file:///\(id).mp3", durationMs: 60_000)
        )
    }

    private func withEpisode(_ body: (SessionEngine, CloseSourcePlayer, SQLiteSessionStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-close-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appendingPathComponent("library.sqlite").path)
        try store.saveItem(Self.episode())
        let audio = CloseSourcePlayer()
        let engine = SessionEngine(
            profile: .init(id: "phone", displayName: "Phone", capabilities: [
                "sync": ["canonical_persistence"], "playback": ["native_media"]
            ]),
            repository: store, audio: audio
        )
        _ = try engine.startSession(itemId: "episode")
        audio.advance(by: 12_000)
        _ = try engine.syncPlaybackProgress()
        try body(engine, audio, store)
    }
}

/// A deterministic transport for lifecycle checks; no audio is encoded or played.
private final class CloseSourcePlayer: AudioPlaybackClient {
    var isPlaying = false
    var starts = 0
    var mediaTimeMs = 0
    var onStop: (() -> Void)?
    var stopError: Error?
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        self.mediaTimeMs = mediaTimeMs
        starts += 1
        isPlaying = true
    }
    func pause() throws { isPlaying = false }
    func stop() throws {
        onStop?()
        if let stopError { throw stopError }
        isPlaying = false
    }
    func currentMediaTimeMs() -> Int? { mediaTimeMs }
    func currentPlaybackDurationMs() -> Int? { 60_000 }
    func advance(by milliseconds: Int) { if isPlaying { mediaTimeMs += milliseconds } }
}
