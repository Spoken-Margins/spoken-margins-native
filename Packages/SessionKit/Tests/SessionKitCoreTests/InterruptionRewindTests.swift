import Foundation
import XCTest
@testable import SessionKit

/// #1975: after a call or Siri a podcast resumed exactly where iOS paused it. It now steps back by how long the
/// interruption lasted, so the listener picks up the thread.
final class InterruptionRewindTests: XCTestCase {
    func testTheStepGrowsWithTheTimeAway() {
        let table: [(seconds: TimeInterval, ms: Int)] = [
            (0, 0), (0.5, 0), (1.999, 0),
            (2, 3_000), (10, 3_000), (30, 3_000),
            (30.001, 6_000), (120, 6_000), (300, 6_000),
            (300.001, 10_000), (3_600, 10_000), (86_400 * 30, 10_000),
        ]
        for (seconds, ms) in table {
            XCTAssertEqual(InterruptionRewind.rewindMs(pausedForSeconds: seconds), ms, "\(seconds) s away")
        }
    }

    func testUnreadableDurationsStepNowhereOrToTheCap() {
        XCTAssertEqual(InterruptionRewind.rewindMs(pausedForSeconds: -5), 0, "a clock that ran backwards")
        XCTAssertEqual(InterruptionRewind.rewindMs(pausedForSeconds: -.infinity), 0)
        XCTAssertEqual(InterruptionRewind.rewindMs(pausedForSeconds: .nan), 0)
        XCTAssertEqual(InterruptionRewind.rewindMs(pausedForSeconds: .infinity), 10_000)
    }

    // MARK: Through the engine

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
        media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: InterruptionRewindTests.durationMs)
    )

    private final class Podcast: AudioPlaybackClient {
        var mediaTimeMs: Int? = 0
        var events: [String] = []
        /// iOS refusing to reactivate the audio session for one start (#2183).
        var failNextPlay = false
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { events.append("play") }
        func play(targetId: String, from charOffset: Int) throws { events.append("play") }
        func play(targetId: String, fromMediaTimeMs t: Int) throws {
            if failNextPlay { failNextPlay = false; events.append("refused@\(t)"); throw SessionKitError.invalidCommandForState("play") }
            mediaTimeMs = t; events.append("play@\(t)")
        }
        func pause() throws { events.append("pause") }
        func currentCharOffset() -> Int? { nil }
        func currentMediaTimeMs() -> Int? { mediaTimeMs }
        func currentPlaybackPosition() -> PlaybackPosition? {
            mediaTimeMs.map { PlaybackPosition(mediaTimeMs: $0, durationMs: InterruptionRewindTests.durationMs, anchorConfidence: .mediaTime) }
        }
    }

    private final class Recorder: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// The episode playing at `positionMs`, then paused by the system (as a call does).
    private func interrupted(at positionMs: Int) throws -> (engine: SessionEngine, audio: Podcast, clock: Clock) {
        let audio = Podcast()
        let clock = Clock()
        let repository = InMemorySessionRepository(items: [episode.id: episode])
        let engine = SessionEngine(
            profile: profile, repository: repository, audio: audio, recorder: Recorder(), now: { clock.date }
        )
        _ = try engine.startSession(itemId: episode.id)
        audio.mediaTimeMs = positionMs
        _ = try engine.reconcileSystemInitiatedPause()
        audio.events.removeAll()
        return (engine, audio, clock)
    }

    func testAResumeAfterAMinuteAwayStepsBack() throws {
        let (engine, audio, clock) = try interrupted(at: 600_000)
        clock.date.addTimeInterval(60)

        let snapshot = try engine.resumePlaybackAfterInterruption()

        XCTAssertEqual(audio.events, ["play@594000"])
        XCTAssertEqual(snapshot.currentMediaTimeMs, 594_000)
        XCTAssertTrue(snapshot.status.isPlaybackActive)
    }

    func testTheStepFollowsTheTimeAway() throws {
        for (awaySeconds, expectedMs) in [(1.0, 600_000), (10.0, 597_000), (120.0, 594_000), (3_600.0, 590_000)] {
            let (engine, audio, clock) = try interrupted(at: 600_000)
            clock.date.addTimeInterval(awaySeconds)

            _ = try engine.resumePlaybackAfterInterruption()

            XCTAssertEqual(audio.events, ["play@\(expectedMs)"], "\(awaySeconds) s away")
        }
    }

    func testTheStepNeverGoesBeforeTheStart() throws {
        let (engine, audio, clock) = try interrupted(at: 1_500)
        clock.date.addTimeInterval(600)

        _ = try engine.resumePlaybackAfterInterruption()

        XCTAssertEqual(audio.events, ["play@0"])
    }

    func testAListenerWhoMovedTheEpisodeKeepsTheirPlace() throws {
        let (engine, audio, clock) = try interrupted(at: 600_000)
        _ = try engine.seekMedia(toMediaTimeMs: 900_000)
        audio.events.removeAll()
        clock.date.addTimeInterval(600)

        _ = try engine.resumePlaybackAfterInterruption()

        XCTAssertEqual(audio.events, ["play@900000"], "a place the listener chose is theirs")
    }

    func testAPauseByTheListenerIsNotAnInterruption() throws {
        let (engine, audio, clock) = try interrupted(at: 600_000)
        _ = try engine.resumePlayback()
        _ = try engine.pause()
        audio.events.removeAll()
        clock.date.addTimeInterval(600)

        _ = try engine.resumePlaybackAfterInterruption()

        XCTAssertEqual(audio.events, ["play@600000"], "only a pause the system made steps back")
    }

    func testARefusedResumeThatIsRetriedStepsBackOnlyOnce() throws {
        let (engine, audio, clock) = try interrupted(at: 600_000)
        clock.date.addTimeInterval(60)
        audio.failNextPlay = true
        XCTAssertThrowsError(try engine.resumePlaybackAfterInterruption())
        audio.events.removeAll()
        clock.date.addTimeInterval(2)

        _ = try engine.resumePlaybackAfterInterruption() // the retrier's second attempt (#2183)

        XCTAssertEqual(audio.events, ["play@594000"], "the retry plays from the stepped-back place, not further back")
    }

    func testTheStepStopsAtTheChapterTheListenerWasIn() throws {
        // #1975: they tapped chapter 2 (10:00), heard a second of it, and the call came. Resuming at 9:54 would play
        // the end of chapter 1, which they chose to skip.
        let audio = Podcast()
        let clock = Clock()
        let repository = InMemorySessionRepository(items: [episode.id: episode])
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "timeline-episode", itemId: episode.id, createdAt: clock.date,
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(id: "s1", startMs: 0, endMs: 600_000, text: "First part."),
                    MediaTimelineSegment(id: "s2", startMs: 600_000, endMs: Self.durationMs, text: "Second part."),
                ],
                chapters: [
                    MediaTimelineChapter(id: "ch-1", title: "One", startMs: 0, transcriptSegmentId: "s1"),
                    MediaTimelineChapter(id: "ch-2", title: "Two", startMs: 600_000, transcriptSegmentId: "s2"),
                ],
                durationMs: Self.durationMs
            )
        ))
        let engine = SessionEngine(
            profile: profile, repository: repository, audio: audio, recorder: Recorder(), now: { clock.date }
        )
        _ = try engine.startSession(itemId: episode.id)
        audio.mediaTimeMs = 601_000
        _ = try engine.reconcileSystemInitiatedPause()
        audio.events.removeAll()
        clock.date.addTimeInterval(60)

        _ = try engine.resumePlaybackAfterInterruption()

        XCTAssertEqual(audio.events, ["play@600000"], "6 s back would be 595000, in the chapter they skipped")
    }

    func testAnEpisodeThatEndedAsTheCallCameInFinishesInsteadOfReplayingItsTail() throws {
        let (engine, audio, clock) = try interrupted(at: Self.durationMs - 100)
        clock.date.addTimeInterval(60)

        let snapshot = try engine.resumePlaybackAfterInterruption()

        XCTAssertEqual(audio.events, [])
        XCTAssertEqual(snapshot.phase, .finished)
    }
}
