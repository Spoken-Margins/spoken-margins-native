import Foundation
import XCTest
@testable import SessionKit

/// #588: resuming after a Margin at the last second of an episode starts the player at its end,
/// where it can never confirm a start. Scrubbing back then waited on that start and failed with
/// `playback_start_timeout`. The owner's rule: a seek keeps the transport state, so playing stays
/// playing, and paused or ended stays paused.
final class EpisodeEndSeekTests: XCTestCase {
    private let durationMs = 178_808
    private var now = Date(timeIntervalSince1970: 1_000)

    func testAStartAtTheEndPausesThereAndASeekBackStaysPausedWithoutFailing() throws {
        let (engine, audio) = try engineResumingAtTheEnd()
        XCTAssertEqual(audio.mediaPlays, [durationMs - 800])

        let ended = try engine.syncPlaybackProgress()
        XCTAssertEqual(ended.status, .paused, "the episode ended, so the start is over")
        XCTAssertNil(ended.lastFailure)
        XCTAssertEqual(audio.pauses, 1, "the player is told it's paused too")

        let scrubbed = try engine.seekMedia(toMediaTimeMs: 0)
        XCTAssertEqual(scrubbed.status, .paused)
        XCTAssertEqual(scrubbed.currentMediaTimeMs, 0)

        now += 10
        let later = try engine.syncPlaybackProgress()
        XCTAssertEqual(later.status, .paused)
        XCTAssertNil(later.lastFailure, "no start timeout after the start watchdog's deadline")
        XCTAssertEqual(audio.mediaPlays.count, 1, "a seek doesn't start playback")
    }

    func testASeekStraightFromAnEndedStartStaysPaused() throws {
        let (engine, audio) = try engineResumingAtTheEnd()

        let scrubbed = try engine.seekMedia(toMediaTimeMs: 0)
        XCTAssertEqual(scrubbed.status, .paused)
        XCTAssertEqual(audio.pauses, 1)

        now += 10
        let later = try engine.syncPlaybackProgress()
        XCTAssertEqual(later.status, .paused)
        XCTAssertNil(later.lastFailure)
    }

    func testAnEpisodeThatPlayedToItsEndStaysPausedAtTheScrubbedPlace() throws {
        let (engine, audio) = try engine(startingAt: 170_000)
        audio.startStatus = .confirmed
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing)

        audio.mediaTimeMs = durationMs
        audio.ended = true
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .paused)

        XCTAssertEqual(try engine.seekMedia(toMediaTimeMs: 0).status, .paused)
        now += 10
        let later = try engine.syncPlaybackProgress()
        XCTAssertEqual(later.status, .paused)
        XCTAssertEqual(later.currentMediaTimeMs, 0, "the scrub isn't undone by the old end")
        XCTAssertNil(later.lastFailure)
    }

    func testAnEndedStartFirstSeenAfterTheWatchdogDeadlineStillPauses() throws {
        let (engine, _) = try engineResumingAtTheEnd()
        now += 10

        let ended = try engine.syncPlaybackProgress()
        XCTAssertEqual(ended.status, .paused, "an ended episode is not a start timeout")
        XCTAssertNil(ended.lastFailure)
    }

    func testScrubbingBackOneSecondFromTheEndKeepsThatPlaceForTheNextPlay() throws {
        let (engine, audio) = try engine(startingAt: 170_000)
        audio.startStatus = .confirmed
        _ = try engine.syncPlaybackProgress()
        audio.mediaTimeMs = durationMs
        audio.ended = true
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .paused)

        let oneSecondBack = durationMs - 1_000
        XCTAssertEqual(try engine.seekMedia(toMediaTimeMs: oneSecondBack).status, .paused)
        XCTAssertEqual(try engine.syncPlaybackProgress().currentMediaTimeMs, oneSecondBack)

        _ = try engine.resumePlayback()
        XCTAssertEqual(audio.mediaPlays.last, oneSecondBack, "Play starts where the listener scrubbed to")
    }

    func testScrubbingNearTheEndAfterThePlayerStoppedShortKeepsThatPlace() throws {
        // AVPlayer can stop a few hundred milliseconds short of the end without its end
        // notification; the adapter infers the end from the stopped position instead.
        let (engine, audio) = try engine(startingAt: 170_000)
        audio.startStatus = .confirmed
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing)
        audio.mediaTimeMs = durationMs - 950
        audio.stoppedShortOfTheEnd = true
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .paused)

        let nearTheEnd = durationMs - 1_000
        XCTAssertEqual(try engine.seekMedia(toMediaTimeMs: nearTheEnd).status, .paused)
        let later = try engine.syncPlaybackProgress()
        XCTAssertEqual(later.status, .paused)
        XCTAssertEqual(audio.pauses, 1, "the player is told it's paused, so the end isn't inferred again")

        _ = try engine.resumePlayback()
        XCTAssertEqual(audio.mediaPlays.last, nearTheEnd, "the scrub isn't undone by the inferred end")
    }

    func testASeekWhilePlayingKeepsPlaying() throws {
        let (engine, audio) = try engine(startingAt: 60_000)
        audio.startStatus = .confirmed
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing)

        XCTAssertEqual(try engine.seekMedia(toMediaTimeMs: 0).status, .playing)
        now += 10
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing)
    }

    func testASeekWhilePausedStaysPaused() throws {
        let (engine, audio) = try engine(startingAt: 60_000)
        audio.startStatus = .confirmed
        _ = try engine.syncPlaybackProgress()
        XCTAssertEqual(try engine.pause().status, .paused)

        XCTAssertEqual(try engine.seekMedia(toMediaTimeMs: 0).status, .paused)
        now += 10
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .paused)
        XCTAssertEqual(audio.mediaPlays.count, 1)
    }

    func testAConfirmedStartClearsAnEarlierStartFailure() throws {
        let (engine, audio) = try engine(startingAt: 60_000)
        now += 10
        let failed = try engine.syncPlaybackProgress()
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastFailure, "playback_start_failed:playback_start_timeout")

        audio.startStatus = .confirmed
        let resumed = try engine.resumePlayback()
        XCTAssertEqual(resumed.status, .playing)
        XCTAssertNil(resumed.lastFailure, "a playing episode no longer reports the old start failure")
        XCTAssertNil(try engine.syncPlaybackProgress().lastFailure)
    }

    func testAPendingStartThatConfirmsLaterClearsAnEarlierStartFailure() throws {
        let (engine, audio) = try engine(startingAt: 60_000)
        now += 10
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .failed)

        XCTAssertEqual(try engine.resumePlayback().status, .starting)
        audio.startStatus = .confirmed
        let playing = try engine.syncPlaybackProgress()
        XCTAssertEqual(playing.status, .playing)
        XCTAssertNil(playing.lastFailure)
    }

    // MARK: - Fixture

    private func engineResumingAtTheEnd() throws -> (SessionEngine, EpisodeAudioClient) {
        // The owner's Margin was at 2:58 of 2:58; a start within AVPlayer's end tolerance ends at once.
        let (engine, audio) = try engine(startingAt: durationMs - 800, endsWhenStartedAtTheEnd: true)
        XCTAssertEqual(engine.snapshot.status, .starting)
        return (engine, audio)
    }

    private func engine(startingAt mediaTimeMs: Int, endsWhenStartedAtTheEnd: Bool = false) throws -> (SessionEngine, EpisodeAudioClient) {
        let url = "file:///episodes/hard-fork.mp3"
        let item = Item(
            id: "item-588", title: "What's Next", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: url, durationMs: durationMs)
        )
        let session = Session(
            id: "session-588", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: url,
            position: Position(mediaTimeMs: mediaTimeMs), completionPercent: 50, playbackRate: 1
        )
        let audio = EpisodeAudioClient(durationMs: durationMs, endsWhenStartedAtTheEnd: endsWhenStartedAtTheEnd)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
            ),
            repository: InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session]),
            audio: audio,
            playbackStartTimeout: 5,
            now: { [unowned self] in self.now }
        )
        _ = try engine.inspectSession(sessionId: session.id)
        let started = try engine.resumePlayback()
        XCTAssertEqual(started.status, .starting)
        return (engine, audio)
    }
}

/// A media player as AVPlayer behaves at an episode's end: a start there reaches the end at once
/// and never reports playing, a start or a seek away from the end clears the completion, and a
/// seek doesn't play.
private final class EpisodeAudioClient: AudioPlaybackClient {
    let durationMs: Int
    let endsWhenStartedAtTheEnd: Bool
    var startStatus: PlaybackStartStatus = .pending
    var activeTargetId: String?
    var mediaTimeMs: Int?
    var ended = false
    /// The player paused itself just short of the end; the adapter infers the end from the
    /// position unless the listener paused (MediaPlaybackCompletionPolicy.reachedEffectiveEnd).
    var stoppedShortOfTheEnd = false
    var listenerPaused = false
    var mediaPlays: [Int] = []
    var pauses = 0

    init(durationMs: Int, endsWhenStartedAtTheEnd: Bool) {
        self.durationMs = durationMs
        self.endsWhenStartedAtTheEnd = endsWhenStartedAtTheEnd
    }

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }
    func play(targetId: String, from charOffset: Int) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }
    func play(targetId: String, seekingTo charOffset: Int) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        self.mediaTimeMs = mediaTimeMs
        mediaPlays.append(mediaTimeMs)
        listenerPaused = false
        stoppedShortOfTheEnd = false
        ended = endsWhenStartedAtTheEnd && durationMs - mediaTimeMs <= 1_500
    }

    func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        self.mediaTimeMs = mediaTimeMs
        // As AVPlayerStreamPlaybackClient.requestMediaSeek: any seek before the end clears it.
        if mediaTimeMs < durationMs { ended = false }
    }

    func pause() throws {
        pauses += 1
        listenerPaused = true
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map {
            PlaybackPosition(targetId: activeTargetId, mediaTimeMs: $0, durationMs: durationMs, playbackRate: 1, anchorConfidence: .mediaTime)
        }
    }

    func isPlaybackComplete(targetId: String) -> Bool { isOver && targetId == activeTargetId }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { isOver ? .pending : startStatus }

    private var isOver: Bool {
        if ended { return true }
        guard stoppedShortOfTheEnd, !listenerPaused, let mediaTimeMs, mediaTimeMs > 0 else { return false }
        return durationMs - mediaTimeMs <= 1_500
    }
}
