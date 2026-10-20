import Foundation
import XCTest
@testable import SessionKit

/// #2098: while a start was pending the button showed a spinner, and a tap on it paused, as if the spinner were a
/// play button that had not finished. The face now says what a tap does, and these tests tie it to the engine's
/// own toggle, so the button and the Lock Screen command cannot drift apart again.
/// Async only because Linux XCTest can't run a synchronous main-actor test.
@MainActor
final class PlayPauseFaceTests: XCTestCase {
    func testAPendingStartShowsACancelFaceAndATapCancelsIt() async throws {
        let (engine, audio) = try makeEngine()
        audio.confirmed = false
        let starting = try engine.resumePlayback()
        XCTAssertEqual(starting.status, .starting)

        let face = PlayPauseFace(status: starting.status, isPlaying: starting.status.isPlaybackActive)
        XCTAssertEqual(face, .cancelStart)
        XCTAssertTrue(face.tapStops, "the face must say a tap stops, because the engine's toggle pauses a pending start")
        XCTAssertEqual(try engine.togglePlayPause().status, .paused)
    }

    func testEveryStatusTapStopsExactlyWhenTheEnginesToggleWouldPause() async throws {
        for status in [PlaybackStatus.idle, .starting, .playing, .paused, .recording, .failed] {
            let face = PlayPauseFace(status: status, isPlaying: status.isPlaybackActive)
            XCTAssertEqual(face.tapStops, status.isPlaybackActive, "\(status): the face promises what togglePlayPause does")
        }
    }

    /// The model sends a tap to a Margin's voice, a skim or a finished item's replay before it reaches the source, so
    /// a pending start of the source must not read as the thing that tap cancels.
    func testAPendingStartIsNotACancelWhenTheTapGoesToSomethingElse() {
        XCTAssertEqual(PlayPauseFace(status: .starting, isPlaying: true, tapReachesTheSource: false), .pause)
        XCTAssertEqual(PlayPauseFace(status: .starting, isPlaying: false, tapReachesTheSource: false), .play)
        XCTAssertEqual(PlayPauseFace(status: .starting, isPlaying: true, tapReachesTheSource: true), .cancelStart)
    }

    func testPlayAndPauseKeepTheirWords() {
        XCTAssertEqual(PlayPauseFace(status: .paused, isPlaying: false), .play)
        XCTAssertEqual(PlayPauseFace(status: .playing, isPlaying: true), .pause)
        XCTAssertEqual(PlayPauseFace.play.accessibilityLabel(isMedia: false), "Play")
        XCTAssertEqual(PlayPauseFace.pause.accessibilityLabel(isMedia: false), "Pause")
        XCTAssertNil(PlayPauseFace.pause.accessibilityHint)
    }

    func testTheCancelFaceNamesWhatItIsWaitingForAndThatATapCancels() {
        XCTAssertEqual(PlayPauseFace.cancelStart.accessibilityLabel(isMedia: false), "Preparing voice… Cancel")
        XCTAssertEqual(PlayPauseFace.cancelStart.accessibilityLabel(isMedia: true), "Loading audio… Cancel")
        XCTAssertNotNil(PlayPauseFace.cancelStart.accessibilityHint)
    }

    private func makeEngine() throws -> (SessionEngine, PendingStartClient) {
        let item = Item(
            id: "item-2098", title: "Article", mediaType: "text",
            text: "First sentence of the article. Second sentence of the article.",
            externalReference: nil, status: "ready"
        )
        let session = Session(
            id: "session-2098", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item.id,
            position: Position(charOffset: 31), completionPercent: 40, playbackRate: 1
        )
        let audio = PendingStartClient()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: [
                    "sync": ["canonical_persistence"], "playback": ["realtime_tts"],
                    "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"],
                ]
            ),
            repository: InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session]),
            audio: audio
        )
        _ = try engine.inspectSession(sessionId: session.id)
        return (engine, audio)
    }
}

/// On-device narration whose start stays pending until the test confirms it.
private final class PendingStartClient: AudioPlaybackClient {
    var confirmed = false
    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {}
    func play(targetId: String, from charOffset: Int) throws {}
    func play(targetId: String, seekingTo charOffset: Int) throws {}
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {}
    func seek(toMediaTimeMs mediaTimeMs: Int) throws {}
    func pause() throws {}
    func currentPlaybackPosition() -> PlaybackPosition? {
        PlaybackPosition(targetType: .itemTextTTS, targetId: "item-2098", textStart: 31, textEnd: 37)
    }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { confirmed ? .confirmed : .pending }
}
