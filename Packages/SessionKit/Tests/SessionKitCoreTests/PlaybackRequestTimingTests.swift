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

    private func makeEngine() throws -> (SessionEngine, ActivatingAudioClient) {
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
                capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
            ),
            repository: InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session]),
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
