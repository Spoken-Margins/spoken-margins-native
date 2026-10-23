import Foundation
import XCTest
@testable import SessionKit

/// #2097: Play on an episode saved 52 ms from its end sought a stream into its last instant. The seek took 28 s,
/// the start sat pending, and the X on the pill did nothing for 26 s. A start inside the last half second now finishes the
/// item instead of seeking into its tail.
final class EndOfMediaStartTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online", displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ]
    )

    private static let durationMs = 4_281_339

    private let episode = Item(
        id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
        externalReference: "https://example.com/episode", status: "ready", externalReferenceType: "url",
        media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: EndOfMediaStartTests.durationMs)
    )

    private final class Podcast: AudioPlaybackClient {
        var mediaTimeMs: Int? = 0
        var events: [String] = []
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { events.append("play") }
        func play(targetId: String, from charOffset: Int) throws { events.append("play") }
        func play(targetId: String, fromMediaTimeMs t: Int) throws { mediaTimeMs = t; events.append("play@\(t)") }
        func pause() throws { events.append("pause") }
        func currentCharOffset() -> Int? { nil }
        func currentMediaTimeMs() -> Int? { mediaTimeMs }
        func currentPlaybackPosition() -> PlaybackPosition? {
            mediaTimeMs.map { PlaybackPosition(mediaTimeMs: $0, durationMs: EndOfMediaStartTests.durationMs, anchorConfidence: .mediaTime) }
        }
    }

    private final class Recorder: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    /// The episode paused with `remainingMs` left.
    private func pausedEpisode(remainingMs: Int) throws -> (engine: SessionEngine, audio: Podcast) {
        let audio = Podcast()
        let repository = InMemorySessionRepository(items: [episode.id: episode])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio, recorder: Recorder())
        _ = try engine.startSession(itemId: episode.id)
        audio.mediaTimeMs = Self.durationMs - remainingMs
        _ = try engine.pause()
        audio.events.removeAll()
        return (engine, audio)
    }

    func testAStartFiftyMillisecondsFromTheEndNeverSeeksIntoTheTail() throws {
        let (engine, audio) = try pausedEpisode(remainingMs: 52)

        let snapshot = try engine.resumePlayback()

        XCTAssertEqual(audio.events, [], "nothing is asked of the player: no seek into the last instant, no start to wait on")
        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .finished, "it is the end, as a natural end would leave it")
        XCTAssertFalse(snapshot.status.isPlaybackActive, "no start is pending for the X to wait behind")
    }

    func testTheEdgeOfTheLastHalfSecondIsTheEnd() throws {
        let (atEdge, edgeAudio) = try pausedEpisode(remainingMs: 500)
        XCTAssertEqual(try atEdge.resumePlayback().phase, .finished)
        XCTAssertEqual(edgeAudio.events, [])

        let (outside, outsideAudio) = try pausedEpisode(remainingMs: 500 + 1)
        XCTAssertNotEqual(try outside.resumePlayback().phase, .finished)
        XCTAssertEqual(outsideAudio.events, ["play@\(Self.durationMs - 500 - 1)"])
    }

    func testAPlacePastTheStoredLengthIsNotTheEnd() throws {
        // #2189: a stored length can be a little short of the real file (corrections under 1 s are skipped, and a
        // feed length can miss dynamic ads). A Margin at 0.8 s before the real end sits past that stored length, so
        // "length minus place" is negative. That is a place the listener meant, not the end.
        for pastMs in [1, 100, 900] {
            let (engine, audio) = try pausedEpisode(remainingMs: -pastMs)

            let snapshot = try engine.resumePlayback()

            XCTAssertEqual(audio.events, ["play@\(Self.durationMs + pastMs)"], "\(pastMs) ms past the stored length")
            XCTAssertNotEqual(snapshot.phase, .finished, "\(pastMs) ms past the stored length")
            XCTAssertTrue(snapshot.status.isPlaybackActive)
        }
    }

    func testAPlaceChosenOneSecondFromTheEndStillPlaysThere() throws {
        // #643 and #588: a scrub to 1 s from the end, or a Margin at the last second (0.8 s), is a place the
        // listener meant. Only a position inside the player's own seek tolerance of the end counts as the end.
        for remainingMs in [800, 1_000, 40_000] {
            let (engine, audio) = try pausedEpisode(remainingMs: remainingMs)

            let snapshot = try engine.resumePlayback()

            XCTAssertEqual(audio.events, ["play@\(Self.durationMs - remainingMs)"], "\(remainingMs) ms left")
            XCTAssertTrue(snapshot.status.isPlaybackActive)
        }
    }
}
