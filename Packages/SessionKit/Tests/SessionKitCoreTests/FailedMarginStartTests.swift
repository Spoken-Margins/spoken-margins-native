import Foundation
import XCTest
@testable import SessionKit

/// #1034: Add Margin pauses the source before the microphone starts. When the recorder then can't
/// start (a call holds the audio session, or `AVAudioRecorder.record()` returns false) the engine
/// threw but left the source paused while the snapshot still said `playing`. Nothing was playing and
/// the screen said it was. A failed start now leaves the source and the snapshot as they were.
final class FailedMarginStartTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"],
            "timeline": ["transcript_segments", "media_time", "chapter_timing"],
            "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"]
        ]
    )

    private let text = "First sentence. Second sentence."
    private let mediaUrl = "file:///episodes/walk.mp3"
    private let mediaDurationMs = 600_000

    // MARK: - Text source

    func testAFailedStartKeepsAPlayingSourcePlaying() throws {
        let fixture = try startedArticle()
        XCTAssertTrue(fixture.player.isPlaying)
        let startsBefore = fixture.player.starts

        XCTAssertThrowsError(try fixture.engine.beginInterjection()) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed("recording_failed"))
        }

        XCTAssertTrue(fixture.player.isPlaying, "the source plays on after a failed start")
        XCTAssertEqual(fixture.player.starts, startsBefore + 1, "it was paused for the microphone, then resumed")
        assertSnapshotMatchesPlayer(fixture)
        XCTAssertEqual(fixture.engine.snapshot.phase, .itemPlayback)
        XCTAssertFalse(fixture.engine.snapshot.isRecording)
        XCTAssertNil(fixture.engine.snapshot.recordingTargetId)
    }

    func testAFailedStartLeavesNothingRecordingSoTheNextTapStartsCleanly() throws {
        let fixture = try startedArticle()
        XCTAssertThrowsError(try fixture.engine.beginInterjection())

        XCTAssertThrowsError(
            try fixture.engine.finishInterjection(audioRef: "interjections/never-started.m4a"),
            "no recording target is left behind to save a Margin against"
        )
        XCTAssertEqual(try fixture.repository.loadInterjections(sessionId: fixture.sessionId).count, 0)

        fixture.recorder.refusesToStart = false
        XCTAssertTrue(try fixture.engine.beginInterjection().isRecording)
        XCTAssertFalse(fixture.player.isPlaying, "a started recording still pauses the source")
        _ = try fixture.engine.finishInterjection(audioRef: "interjections/second-try.m4a")
        XCTAssertEqual(try fixture.repository.loadInterjections(sessionId: fixture.sessionId).count, 1)
        XCTAssertTrue(fixture.player.isPlaying, "and the source resumes after the Margin is saved")
    }

    func testAFailedStartReleasesTheRecorder() throws {
        let fixture = try startedArticle()
        XCTAssertThrowsError(try fixture.engine.beginInterjection())

        XCTAssertEqual(fixture.recorder.beginCount, 1)
        XCTAssertEqual(fixture.recorder.cancelCount, 1, "whatever the failed start grabbed, such as the audio session, is let go")
    }

    func testAFailedStartKeepsAPausedSourcePaused() throws {
        let fixture = try startedArticle()
        _ = try fixture.engine.pause()
        let startsBefore = fixture.player.starts
        XCTAssertFalse(fixture.player.isPlaying)

        XCTAssertThrowsError(try fixture.engine.beginInterjection())

        XCTAssertFalse(fixture.player.isPlaying, "a source the listener had paused is not started by a failed Margin")
        XCTAssertEqual(fixture.player.starts, startsBefore)
        assertSnapshotMatchesPlayer(fixture)
        XCTAssertEqual(fixture.engine.snapshot.status, .paused)
    }

    // MARK: - Finished item

    func testAFailedStartOnAFinishedItemStaysFinishedAndStopped() throws {
        let fixture = try finishedArticle()
        XCTAssertEqual(fixture.engine.snapshot.phase, .finished)

        XCTAssertThrowsError(try fixture.engine.beginInterjection())

        XCTAssertEqual(fixture.engine.snapshot.phase, .finished, "the finished screen stays")
        XCTAssertEqual(fixture.engine.snapshot.status, .paused)
        XCTAssertEqual(fixture.player.starts, 0, "a finished source must not play again")
        let session = try XCTUnwrap(fixture.repository.loadSession(id: fixture.sessionId))
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.position.charOffset, text.count)
        XCTAssertEqual(session.completionPercent, 100)

        fixture.recorder.refusesToStart = false
        _ = try fixture.engine.beginInterjection()
        let saved = try fixture.engine.finishInterjection(audioRef: "interjections/recap.m4a")
        XCTAssertEqual(saved.phase, .finished, "a retried recap Margin still returns to the finished state")
        XCTAssertEqual(fixture.player.starts, 0)
    }

    // MARK: - Podcast or other media

    func testAFailedStartResumesAMediaSourceWhereItWasPausedForTheMicrophone() throws {
        let fixture = try startedEpisode(atMediaTimeMs: 90_000)
        fixture.player.mediaTimeMs = 93_500
        XCTAssertTrue(fixture.player.isPlaying)

        XCTAssertThrowsError(try fixture.engine.beginInterjection())

        XCTAssertTrue(fixture.player.isPlaying)
        XCTAssertEqual(fixture.player.mediaStarts.last, 93_500, "it picks up at the frozen clock, not at the old start")
        assertSnapshotMatchesPlayer(fixture)
        XCTAssertNil(fixture.engine.snapshot.recordingTargetId)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let engine: SessionEngine
        let player: TransportPlayer
        let recorder: RefusingRecorder
        let repository: InMemorySessionRepository
        let sessionId: String
    }

    private func assertSnapshotMatchesPlayer(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            fixture.engine.snapshot.status.isPlaybackActive, fixture.player.isPlaying,
            "the snapshot says \(fixture.engine.snapshot.status) while the player is \(fixture.player.isPlaying ? "playing" : "paused")",
            file: file, line: line
        )
    }

    private func makeFixture(items: [Item], sessions: [Session] = []) -> Fixture {
        let player = TransportPlayer()
        let recorder = RefusingRecorder()
        let repository = InMemorySessionRepository(
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }),
            interjections: [:]
        )
        let engine = SessionEngine(profile: profile, repository: repository, audio: player, recorder: recorder)
        return Fixture(engine: engine, player: player, recorder: recorder, repository: repository, sessionId: sessions.first?.id ?? "")
    }

    private var article: Item {
        Item(id: "item-article", title: "Article", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    private func startedArticle() throws -> Fixture {
        let fixture = makeFixture(items: [article])
        let started = try fixture.engine.startSession(itemId: article.id)
        XCTAssertTrue(started.status.isPlaybackActive)
        return Fixture(
            engine: fixture.engine, player: fixture.player, recorder: fixture.recorder,
            repository: fixture.repository, sessionId: try XCTUnwrap(started.sessionId)
        )
    }

    private func finishedArticle() throws -> Fixture {
        let finished = Session(
            id: "session-article", itemId: article.id, status: "finished", phase: .finished,
            currentTargetType: .itemTextTTS, currentTargetId: article.id,
            position: Position(charOffset: text.count, chapterId: nil), completionPercent: 100, playbackRate: 1
        )
        let fixture = makeFixture(items: [article], sessions: [finished])
        fixture.player.textOffset = 0 // a stopped speech player reports a reset offset
        _ = try fixture.engine.inspectSession(sessionId: finished.id)
        return fixture
    }

    private func startedEpisode(atMediaTimeMs mediaTimeMs: Int) throws -> Fixture {
        let item = Item(
            id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: mediaUrl, durationMs: mediaDurationMs)
        )
        let session = Session(
            id: "session-episode", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: mediaUrl,
            position: Position(mediaTimeMs: mediaTimeMs), completionPercent: 15, playbackRate: 1
        )
        let fixture = makeFixture(items: [item], sessions: [session])
        fixture.player.durationMs = mediaDurationMs
        _ = try fixture.engine.inspectSession(sessionId: session.id)
        let started = try fixture.engine.resumePlayback()
        XCTAssertTrue(started.status.isPlaybackActive)
        return fixture
    }
}

/// A recorder that can't get the microphone until the test lets it, as when a call holds the audio
/// session. It counts how often the engine let go of it.
private final class RefusingRecorder: RecordingClient {
    var refusesToStart = true
    var beginCount = 0
    var cancelCount = 0

    func beginRecording() throws {
        beginCount += 1
        if refusesToStart { throw SessionKitError.persistenceFailed("recording_failed") }
    }

    func finishRecording(audioRef: String?) throws -> String { audioRef ?? "interjections/refusing.m4a" }
    func cancelRecording() throws { cancelCount += 1 }
}

/// A player that knows whether it is playing, so a test can compare it with what the snapshot says.
private final class TransportPlayer: AudioPlaybackClient {
    var isPlaying = false
    var starts = 0
    var mediaStarts: [Int] = []
    var textOffset: Int? = 0
    var mediaTimeMs: Int?
    var durationMs: Int?
    private var activeTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String { text }

    func play(targetId: String) throws {
        activeTargetId = targetId
        isPlaying = true
        starts += 1
    }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        try play(targetId: targetId)
        self.mediaTimeMs = mediaTimeMs
        mediaStarts.append(mediaTimeMs)
    }

    func pause() throws { isPlaying = false }

    func currentCharOffset() -> Int? { textOffset }

    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map {
            PlaybackPosition(targetId: activeTargetId, mediaTimeMs: $0, durationMs: durationMs, playbackRate: 1, anchorConfidence: .mediaTime)
        }
    }
}
