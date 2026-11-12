import Foundation
import XCTest
@testable import SessionKit

/// #4110: a friend's Margin ended with the screen locked, `resumePlayback()` threw once, and the episode stayed paused
/// with one unseen banner. The return must retry, record why with no listener data, and say so when it gives up.
private let marginReturnEpisodeDurationMs = 3_600_000

@MainActor
final class MarginReturnResumeTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online", displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ]
    )
    private let episode = Item(
        id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
        externalReference: "https://example.com/episode", status: "ready", externalReferenceType: "url",
        media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: marginReturnEpisodeDurationMs)
    )

    /// The player refusing to start `refusals` times: iOS refusing to activate the session in the background.
    private final class Podcast: AudioPlaybackClient {
        var mediaTimeMs: Int? = 0
        var refusals = 0
        var starts = 0
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { try start() }
        func play(targetId: String, from charOffset: Int) throws { try start() }
        func play(targetId: String, fromMediaTimeMs t: Int) throws { mediaTimeMs = t; try start() }
        private func start() throws {
            if refusals > 0 { refusals -= 1; throw SessionKitError.invalidCommandForState("play") }
            starts += 1
        }
        func pause() throws {}
        func currentCharOffset() -> Int? { nil }
        func currentMediaTimeMs() -> Int? { mediaTimeMs }
        func currentPlaybackPosition() -> PlaybackPosition? {
            mediaTimeMs.map { PlaybackPosition(mediaTimeMs: $0, durationMs: marginReturnEpisodeDurationMs, anchorConfidence: .mediaTime) }
        }
    }

    private final class Recorder: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    /// The episode paused at 10 minutes, as it is while a friend's Margin plays over it.
    private func pausedForAMargin() throws -> (engine: SessionEngine, audio: Podcast) {
        let audio = Podcast()
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository(items: [episode.id: episode]),
                                   audio: audio, recorder: Recorder())
        _ = try engine.startSession(itemId: episode.id)
        audio.mediaTimeMs = 600_000
        _ = try engine.pause()
        audio.starts = 0
        return (engine, audio)
    }

    private func make(delays: [Int] = [10, 20]) -> MarginReturnResume {
        MarginReturnResume(retrier: InterruptionResumeRetrier(delaysMs: delays, sleep: { _ in }))
    }

    func testARefusedStartIsRetriedAndTheEpisodeResumes() async throws {
        let (engine, audio) = try pausedForAMargin()
        audio.refusals = 1
        let resumer = make()
        var events: [MarginReturnResume.Event] = []

        let resumedAtOnce = resumer.resume(
            stillWaiting: { engine.snapshot.status == .paused },
            attempt: { _ = try engine.resumePlayback() },
            report: { events.append($0) }
        )
        await resumer.waitUntilIdle()

        XCTAssertFalse(resumedAtOnce)
        XCTAssertEqual(audio.starts, 1, "the retry started the episode; without it the episode stays paused")
        XCTAssertTrue(engine.snapshot.status.isPlaybackActive)
        XCTAssertEqual(events, [.failed(reason: "SessionKit.SessionKitError#1:invalidCommandForState"), .resumedOnRetry(attempt: 1)])
    }

    func testAStartThatWorksNeedsNoRetryAndRecordsNothing() async throws {
        let (engine, audio) = try pausedForAMargin()
        let resumer = make()
        var events: [MarginReturnResume.Event] = []

        let resumedAtOnce = resumer.resume(stillWaiting: { true }, attempt: { _ = try engine.resumePlayback() }, report: { events.append($0) })

        XCTAssertTrue(resumedAtOnce)
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(events, [])
        XCTAssertFalse(resumer.isRetrying)
    }

    func testEveryRetryRefusedGivesUpWithTheReasonAndLeavesTheEpisodePaused() async throws {
        let (engine, audio) = try pausedForAMargin()
        audio.refusals = 99
        let resumer = make()
        var events: [MarginReturnResume.Event] = []

        resumer.resume(stillWaiting: { true }, attempt: { _ = try engine.resumePlayback() }, report: { events.append($0) })
        await resumer.waitUntilIdle()

        XCTAssertEqual(audio.starts, 0)
        XCTAssertEqual(engine.snapshot.status, .paused)
        guard case .gaveUp(let attempts, let reason)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(reason.isEmpty)
    }

    func testAListenerWhoTookOverIsNotOverriddenByARetry() async throws {
        let (engine, audio) = try pausedForAMargin()
        audio.refusals = 1
        let resumer = make()
        var events: [MarginReturnResume.Event] = []

        resumer.resume(stillWaiting: { false }, attempt: { _ = try engine.resumePlayback() }, report: { events.append($0) })
        await resumer.waitUntilIdle()

        XCTAssertEqual(audio.starts, 0)
        XCTAssertEqual(events.last, .abandoned(attempts: 0))
    }

    /// The audit's scenario on cbe4653: the listener presses Play on the Lock Screen while a retry waits, then Pause a
    /// moment later in the same place. The source is paused where the Margin left it, so the position check alone says
    /// "still owed". The app model cancels the retry when playback goes active; the retry must then not start the source.
    func testARetryCancelledWhenTheListenerPlayedIsNotRevivedByAPauseInTheSamePlace() async throws {
        let (engine, audio) = try pausedForAMargin()
        audio.refusals = 1
        let gate = AsyncGate()
        let resumer = MarginReturnResume(retrier: InterruptionResumeRetrier(delaysMs: [10], sleep: { _ in await gate.wait() }))
        var events: [MarginReturnResume.Event] = []
        resumer.resume(stillWaiting: { engine.snapshot.status == .paused }, attempt: { _ = try engine.resumePlayback() }, report: { events.append($0) })
        XCTAssertTrue(resumer.isRetrying)

        _ = try engine.resumePlayback() // the listener plays...
        _ = try engine.pause() // ...and pauses again, still in the same place
        XCTAssertEqual(engine.snapshot.status, .paused)
        XCTAssertEqual(audio.starts, 1, "the listener's own Play started the episode once")
        resumer.cancel() // what the model does the moment playback goes active
        await gate.open()
        await resumer.waitUntilIdle()

        XCTAssertEqual(audio.starts, 1, "a retry that ran now would start the episode the listener just paused")
        XCTAssertEqual(events, [.failed(reason: "SessionKit.SessionKitError#1:invalidCommandForState")])
    }

    func testTheRecordCarriesTheOutcomeAndErrorTypeButNeverAMessage() {
        struct Leaky: LocalizedError { var errorDescription: String? { "Could not open /Users/someone/My Secret Plans.mp3" } }
        let failed = MarginReturnResume.Event.failed(reason: SafeErrorText.describe(Leaky()))
        XCTAssertEqual(failed.fields["outcome"], "failed")
        XCTAssertEqual(failed.fields["attempt"], "0")
        for value in failed.fields.values {
            XCTAssertFalse(value.contains("Secret"), value)
            XCTAssertFalse(value.contains("/Users"), value)
        }
        XCTAssertEqual(MarginReturnResume.Event.gaveUp(attempts: 4, reason: "x#1").fields,
                       ["outcome": "gave_up", "attempt": "4", "error": "x#1"])
        XCTAssertEqual(MarginReturnResume.Event.abandoned(attempts: 1).fields, ["outcome": "abandoned", "attempt": "1"])
    }

    func testANewReturnReplacesOneStillRetrying() async throws {
        let (engine, audio) = try pausedForAMargin()
        audio.refusals = 1
        let resumer = MarginReturnResume(retrier: InterruptionResumeRetrier(delaysMs: [10], sleep: { _ in try? await Task.sleep(for: .milliseconds(50)) }))
        resumer.resume(stillWaiting: { true }, attempt: { _ = try engine.resumePlayback() }, report: { _ in })
        XCTAssertTrue(resumer.isRetrying)

        let second = resumer.resume(stillWaiting: { true }, attempt: { _ = try engine.resumePlayback() }, report: { _ in })
        await resumer.waitUntilIdle()

        XCTAssertTrue(second)
        XCTAssertEqual(audio.starts, 1, "one start, not a second from the replaced retry")
        XCTAssertFalse(resumer.isRetrying)
    }

    /// A sleep that returns when released, so a test can act while the retry waits.
    private actor AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
