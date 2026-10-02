import Foundation
import XCTest
@testable import SessionKit

/// #142: a spoken recap Margin on a finished item. Finishing or cancelling the Margin used to resume
/// as if the source had been playing: the phase went back to item playback and the source played
/// again from its saved position, so the finished screen was lost. Its anchor was also re-sampled from
/// a player that had already stopped.
final class FinishedSessionMarginTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence", "browser_session_handoff"],
            "playback": ["realtime_tts", "prerendered_audio", "native_media"],
            "timeline": ["transcript_segments", "media_time", "chapter_timing"],
            "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"]
        ]
    )

    private let text = "First sentence. Second sentence."

    private var article: Item {
        Item(id: "item-article", title: "Article", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    private var finishedSession: Session {
        Session(
            id: "session-article", itemId: article.id, status: "finished", phase: .finished,
            currentTargetType: .itemTextTTS, currentTargetId: article.id,
            position: Position(charOffset: text.count, chapterId: nil), completionPercent: 100, playbackRate: 1
        )
    }

    /// Counts every start, and reports the position a stopped speech player falls back to (0).
    private final class StoppedPlayer: AudioPlaybackClient {
        var playCount = 0
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { playCount += 1 }
        func currentCharOffset() -> Int? { 0 }
        func pause() throws {}
    }

    private func finishedArticle() throws -> (SessionEngine, StoppedPlayer, InMemorySessionRepository) {
        let player = StoppedPlayer()
        let repository = InMemorySessionRepository(
            items: [article.id: article], sessions: [finishedSession.id: finishedSession], interjections: [:]
        )
        let engine = SessionEngine(profile: profile, repository: repository, audio: player)
        let opened = try engine.inspectSession(sessionId: finishedSession.id)
        XCTAssertEqual(opened.phase, .finished)
        return (engine, player, repository)
    }

    func testFinishingASpokenMarginOnAFinishedItemStaysFinished() throws {
        let (engine, player, repository) = try finishedArticle()

        XCTAssertTrue(try engine.beginInterjection().isRecording)
        let saved = try engine.finishInterjection(audioRef: "interjections/recap.m4a")

        XCTAssertEqual(saved.phase, .finished, "the finished screen comes back")
        XCTAssertFalse(saved.status.isPlaybackActive)
        XCTAssertEqual(player.playCount, 0, "the source must not play again")
        let session = try XCTUnwrap(repository.loadSession(id: finishedSession.id))
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.status, "finished")
        XCTAssertEqual(session.position.charOffset, text.count)
        XCTAssertEqual(session.completionPercent, 100)
    }

    func testARecapMarginIsAnchoredAtTheEnd() throws {
        let (engine, _, repository) = try finishedArticle()

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/recap.m4a")

        let margin = try XCTUnwrap(repository.loadInterjections(sessionId: finishedSession.id).first)
        XCTAssertEqual(margin.audioPath, "interjections/recap.m4a")
        XCTAssertEqual(margin.roughPercent, 100, "not at the stopped player's position 0")
        XCTAssertEqual(margin.anchor.startChar, text.count)
    }

    func testCancellingASpokenMarginOnAFinishedItemStaysFinished() throws {
        let (engine, player, repository) = try finishedArticle()

        _ = try engine.beginInterjection()
        let cancelled = try engine.cancelInterjection()

        XCTAssertEqual(cancelled.phase, .finished)
        XCTAssertFalse(cancelled.status.isPlaybackActive)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertTrue(try repository.loadInterjections(sessionId: finishedSession.id).isEmpty)
        XCTAssertEqual(try XCTUnwrap(repository.loadSession(id: finishedSession.id)).phase, .finished)
    }

    /// Replaying after a recap Margin starts from the beginning, even while the new start is
    /// still pending: the recap's protected end position must not carry over.
    func testReplayAfterARecapMarginDoesNotKeepTheOldEnd() throws {
        final class PendingStartPlayer: AudioPlaybackClient {
            func prepareSpeechText(_ text: String) throws -> String { text }
            func play(targetId: String) throws {}
            func currentCharOffset() -> Int? { 0 }
            func playbackStartStatus(targetId: String) -> PlaybackStartStatus { .pending }
            func pause() throws {}
        }
        let repository = InMemorySessionRepository(
            items: [article.id: article], sessions: [finishedSession.id: finishedSession], interjections: [:]
        )
        let engine = SessionEngine(profile: profile, repository: repository, audio: PendingStartPlayer())
        _ = try engine.inspectSession(sessionId: finishedSession.id)
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/recap.m4a")

        _ = try engine.endSession()
        let replay = try engine.startSession(itemId: article.id)

        XCTAssertNotEqual(replay.sessionId, finishedSession.id)
        XCTAssertEqual(replay.currentTextStart, 0)
    }

    /// The same end-of-episode case on a podcast's native media clock.
    func testARecapMarginAtTheEndOfAnEpisodeStaysFinished() throws {
        let episode = Item(
            id: "item-episode", title: "Episode", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "https://example.com/episode.mp3", durationMs: 60_000)
        )
        let finished = Session(
            id: "session-episode", itemId: episode.id, status: "finished", phase: .finished,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "https://example.com/episode.mp3",
            position: Position(charOffset: 0, mediaTimeMs: 60_000, chapterId: nil), completionPercent: 100, playbackRate: 1
        )
        let player = StoppedPlayer()
        let repository = InMemorySessionRepository(
            items: [episode.id: episode], sessions: [finished.id: finished], interjections: [:]
        )
        let engine = SessionEngine(profile: profile, repository: repository, audio: player)
        XCTAssertEqual(try engine.inspectSession(sessionId: finished.id).phase, .finished)

        _ = try engine.beginInterjection()
        let saved = try engine.finishInterjection(audioRef: "interjections/episode-recap.m4a")

        XCTAssertEqual(saved.phase, .finished)
        XCTAssertEqual(player.playCount, 0)
        let margin = try XCTUnwrap(repository.loadInterjections(sessionId: finished.id).first)
        XCTAssertEqual(margin.anchor.mediaTimeMs, 60_000)
        XCTAssertEqual(try XCTUnwrap(repository.loadSession(id: finished.id)).position.mediaTimeMs, 60_000)
    }

    /// Mid-item Margins still resume the source as before (J3).
    func testASpokenMarginMidItemStillResumes() throws {
        var midway = finishedSession
        midway.status = "in_progress"
        midway.phase = .itemPlayback
        midway.position = Position(charOffset: 16, chapterId: nil)
        midway.completionPercent = 50
        let player = StoppedPlayer()
        let repository = InMemorySessionRepository(
            items: [article.id: article], sessions: [midway.id: midway], interjections: [:]
        )
        let engine = SessionEngine(profile: profile, repository: repository, audio: player)
        _ = try engine.inspectSession(sessionId: midway.id)

        _ = try engine.beginInterjection()
        let resumed = try engine.finishInterjection(audioRef: "interjections/mid.m4a")

        XCTAssertEqual(resumed.phase, .itemPlayback)
        XCTAssertEqual(player.playCount, 1)
    }
}
