import Foundation
import XCTest
@testable import SessionKit

/// #357, audit of #580: time to first audio runs from the listener's request, so audio-session activation and
/// player work done before the engine publishes the start count too.
final class PlaybackRequestTimingTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 5_000)

    func testAResumeThatConfirmsAtOnceCarriesTheRequestTime() throws {
        let (engine, audio) = try makeEngine()
        audio.confirmsAtOnce = true
        let tap = now

        let resumed = try engine.resumePlayback()

        XCTAssertEqual(resumed.status, .playing)
        XCTAssertEqual(resumed.playbackRequestedAt, tap, "stamped before the player's 1.5 s of work")
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: resumed.itemId, status: .paused, at: tap - 10)
        XCTAssertEqual(watch.observe(itemId: resumed.itemId, status: resumed.status,
                                     requestedAt: resumed.playbackRequestedAt, at: now),
                       [.firstAudio(itemId: "item-357", milliseconds: 1_500)])
    }

    func testAPendingStartIsTimedFromTheRequest() throws {
        let (engine, audio) = try makeEngine()
        let tap = now

        let starting = try engine.resumePlayback()
        XCTAssertEqual(starting.status, .starting)
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: starting.itemId, status: .paused, at: tap - 10)
        _ = watch.observe(itemId: starting.itemId, status: .starting, requestedAt: starting.playbackRequestedAt, at: now)

        now += 2
        audio.confirmsAtOnce = true
        let playing = try engine.syncPlaybackProgress()
        XCTAssertEqual(playing.status, .playing)
        XCTAssertEqual(watch.observe(itemId: playing.itemId, status: playing.status,
                                     requestedAt: playing.playbackRequestedAt, at: now),
                       [.firstAudio(itemId: "item-357", milliseconds: 3_500)])
    }

    /// Audit of #580: a streamed answer published straight as "starting" gets its own request time, not the one
    /// left on the snapshot by the resume half a minute earlier.
    func testAStreamedStartDoesNotInheritAnEarlierRequestTime() throws {
        let (engine, audio) = try makeEngine()
        audio.confirmsAtOnce = true
        _ = try engine.resumePlayback()
        now += 30
        _ = try engine.pause()
        now += 1
        let ask = now

        let streaming = try engine.activateStreamingTurn(turnId: "turn-357")

        XCTAssertEqual(streaming.status, .starting)
        XCTAssertEqual(streaming.playbackRequestedAt, ask)
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: streaming.itemId, status: .paused, at: ask - 1)
        _ = watch.observe(itemId: streaming.itemId, status: .starting, requestedAt: streaming.playbackRequestedAt, at: now)
        XCTAssertEqual(watch.observe(itemId: streaming.itemId, status: .playing, at: ask + 2),
                       [.firstAudio(itemId: "item-357", milliseconds: 2_000)])
    }

    /// Audit of #580: a Margin's answer started while the article plays is a new start on the same item, so it gets
    /// its own request time and the watch times it.
    func testAnAnswerStartedDuringPlaybackIsANewStart() throws {
        let (engine, audio) = try makeEngine()
        audio.confirmsAtOnce = true
        let playing = try engine.resumePlayback()
        XCTAssertEqual(playing.status, .playing)
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: playing.itemId, targetId: playing.targetId, status: playing.status,
                          requestedAt: playing.playbackRequestedAt, at: now)
        now += 30
        let ask = now

        let answer = try engine.activateStreamingTurn(turnId: "turn-357")

        XCTAssertEqual(answer.status, .starting)
        XCTAssertEqual(answer.playbackRequestedAt, ask)
        XCTAssertEqual(watch.observe(itemId: answer.itemId, targetId: answer.targetId, status: answer.status,
                                     requestedAt: answer.playbackRequestedAt, at: now), [])
        XCTAssertEqual(watch.waitingTargetId, "turn-357")
        XCTAssertEqual(watch.observe(itemId: answer.itemId, targetId: answer.targetId, status: .playing, at: ask + 3),
                       [.firstAudio(itemId: "item-357", milliseconds: 3_000)])
    }

    /// Audit of #580: a seek while playing keeps the start's request time; a new listener command replaces it.
    func testASeekKeepsTheRequestAndANewCommandReplacesIt() throws {
        let (engine, audio) = try makeEngine()
        audio.confirmsAtOnce = true
        let tap = now
        XCTAssertEqual(try engine.resumePlayback().playbackRequestedAt, tap)
        now += 20

        let sought = try engine.seekMedia(toMediaTimeMs: 120_000)
        XCTAssertTrue(sought.status.isPlaybackActive)
        XCTAssertEqual(sought.playbackRequestedAt, tap, "a seek is not a new request")

        now += 20
        let again = now
        let resumed = try engine.resumePlayback()
        XCTAssertTrue(resumed.status.isPlaybackActive)
        XCTAssertEqual(resumed.playbackRequestedAt, again)
    }

    /// Audit of #580: jumping to a saved answer's chapter while the article plays is a new request; another chapter
    /// of the same answer is a seek and keeps it.
    func testAChapterJumpToAnotherTargetIsANewRequest() throws {
        let first = Chapter(id: "ch-1", title: "First", startChar: 0, endChar: 15, percent: 0)
        let second = Chapter(id: "ch-2", title: "Second", startChar: 16, endChar: 29, percent: 50)
        let answer = ConversationTurn(
            id: "turn-357", sessionId: "session-357", role: "assistant", turnType: "assistant_response",
            status: "complete", summary: nil, text: "First response. Second point.", rawText: nil,
            chapters: [first, second], sourceInterjectionIds: []
        )
        let (engine, audio) = try makeEngine(turns: [answer])
        audio.confirmsAtOnce = true
        _ = try engine.resumePlayback()
        now += 30
        let jump = now

        let toAnswer = try engine.jumpToTurnChapter(turnId: answer.id, chapterId: first.id)
        XCTAssertEqual(toAnswer.targetId, answer.id)
        XCTAssertEqual(toAnswer.playbackRequestedAt, jump)

        now += 10
        let within = try engine.jumpToTurnChapter(turnId: answer.id, chapterId: second.id)
        XCTAssertEqual(within.playbackRequestedAt, jump, "another chapter of the same answer is a seek")
    }

    /// Audit of #580: a chapter of the paused answer is a new start, so its time includes the 1.5 s of audio work.
    func testAChapterStartedFromAPauseIsTimedFromTheTap() throws {
        let first = Chapter(id: "ch-1", title: "First", startChar: 0, endChar: 15, percent: 0)
        let second = Chapter(id: "ch-2", title: "Second", startChar: 16, endChar: 29, percent: 50)
        let answer = ConversationTurn(
            id: "turn-357", sessionId: "session-357", role: "assistant", turnType: "assistant_response",
            status: "complete", summary: nil, text: "First response. Second point.", rawText: nil,
            chapters: [first, second], sourceInterjectionIds: []
        )
        let (engine, audio) = try makeEngine(turns: [answer])
        audio.confirmsAtOnce = true
        _ = try engine.jumpToTurnChapter(turnId: answer.id, chapterId: first.id)
        now += 10
        XCTAssertEqual(try engine.pause().targetId, answer.id)
        now += 10
        let tap = now

        let resumed = try engine.jumpToTurnChapter(turnId: answer.id, chapterId: second.id)

        XCTAssertEqual(resumed.status, .playing)
        XCTAssertEqual(resumed.playbackRequestedAt, tap, "stamped before the player's 1.5 s of work")
    }

    /// Audit of #580: the resume after a Margin is recorded (or the recording is cancelled) counts from the tap that
    /// ended the recording, so the 1.5 s of audio work before the resume is published is in its time.
    func testTheResumeAfterAMarginIsTimedFromTheTap() throws {
        for finishes in [true, false] {
            let (engine, audio) = try makeEngine()
            audio.confirmsAtOnce = true
            _ = try engine.resumePlayback()
            now += 10
            _ = try engine.beginInterjection()
            now += 5
            let tap = now

            let resumed = finishes ? try engine.finishInterjection(audioRef: nil) : try engine.cancelInterjection()

            XCTAssertEqual(resumed.status, .playing, finishes ? "finish" : "cancel")
            XCTAssertEqual(resumed.playbackRequestedAt, tap, finishes ? "finish" : "cancel")
        }
    }

    /// Audit of #580: the same holds for a written Margin, saved or cancelled.
    func testTheResumeAfterAWrittenMarginIsTimedFromTheTap() throws {
        for saves in [true, false] {
            let (engine, audio) = try makeEngine()
            audio.confirmsAtOnce = true
            _ = try engine.resumePlayback()
            now += 10
            let capture = try engine.beginWrittenInterjection()
            now += 5
            let tap = now

            let resumed = saves
                ? try engine.saveWrittenInterjection(captureId: capture.id, text: "A note.")
                : try engine.cancelWrittenInterjection(captureId: capture.id)

            XCTAssertEqual(resumed.status, .playing, saves ? "save" : "cancel")
            XCTAssertEqual(resumed.playbackRequestedAt, tap, saves ? "save" : "cancel")
        }
    }

    func testAStaleOrFutureRequestTimeFallsBackToNow() {
        var watch = PlaybackStartWatch()
        let at = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(watch.observe(itemId: "a", status: .playing, requestedAt: at - 600, at: at),
                       [.firstAudio(itemId: "a", milliseconds: 0)])
        _ = watch.observe(itemId: "a", status: .paused, at: at + 1)
        XCTAssertEqual(watch.observe(itemId: "a", status: .playing, requestedAt: at + 60, at: at + 2),
                       [.firstAudio(itemId: "a", milliseconds: 0)])
    }

    // MARK: - Fixture

    private func makeEngine(turns: [ConversationTurn] = []) throws -> (SessionEngine, ActivatingAudioClient) {
        let url = "file:///episodes/357.mp3"
        let item = Item(
            id: "item-357", title: "Silence", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: url, durationMs: 600_000)
        )
        let session = Session(
            id: "session-357", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: url,
            position: Position(mediaTimeMs: 60_000), completionPercent: 10, playbackRate: 1
        )
        let audio = ActivatingAudioClient(advance: { [unowned self] in self.now += 1.5 })
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: [
                    "sync": ["canonical_persistence"], "playback": ["native_media", "assistant_turn_tts"],
                    "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"],
                ]
            ),
            repository: InMemorySessionRepository(
                items: [item.id: item], sessions: [session.id: session],
                turns: Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
            ),
            audio: audio,
            now: { [unowned self] in self.now }
        )
        _ = try engine.inspectSession(sessionId: session.id)
        return (engine, audio)
    }
}

/// A player whose start takes 1.5 s of audio-session activation before it returns.
private final class ActivatingAudioClient: AudioPlaybackClient {
    let advance: () -> Void
    var confirmsAtOnce = false
    var mediaTimeMs = 60_000

    init(advance: @escaping () -> Void) { self.advance = advance }

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { advance() }
    func play(targetId: String, from charOffset: Int) throws { advance() }
    func play(targetId: String, seekingTo charOffset: Int) throws { advance() }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws { advance() }
    func seek(toMediaTimeMs mediaTimeMs: Int) throws { self.mediaTimeMs = mediaTimeMs }
    func pause() throws {}
    func currentPlaybackPosition() -> PlaybackPosition? {
        PlaybackPosition(targetId: nil, mediaTimeMs: mediaTimeMs, durationMs: 600_000, playbackRate: 1, anchorConfidence: .mediaTime)
    }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { confirmsAtOnce ? .confirmed : .pending }
}
