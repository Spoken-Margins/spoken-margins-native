import Foundation
import XCTest
@testable import SessionKit

/// #4831: Siri pauses the playing item and then adds a Margin (Siri's Add Margin on the playing item). The engine used
/// to send the audio client a second `pause()`, which the client treats as the listener's own Pause and answers by
/// cancelling the automatic resume, so the item stayed silent after Siri closed. A source the system already paused is
/// now left for the interruption's end to resume, through begin, Save and Cancel of a written Margin and the start of
/// a recording; the listener's own Pause still cancels it.
final class MarginDuringSystemInterruptionTests: XCTestCase {
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
        media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 4_740_000)
    )

    private let article = Item(
        id: "item-article", title: "Article", mediaType: "text", text: "First sentence. Second sentence. Third sentence.",
        externalReference: nil, status: "ready"
    )

    /// An audio client that answers the way the real ones do (`AVPlayerPlaybackClient`, the Supertonic client): a
    /// system interruption that finds it playing pauses it and arms an automatic resume in the real
    /// `SystemInterruptionResume`, and `pause()` is the listener's Pause, which cancels the arming.
    private final class Client: AudioPlaybackClient {
        var mediaTimeMs: Int? = 600_000
        var charOffset: Int?
        var playing = false
        var resume = SystemInterruptionResume()
        /// A start that gets as far as `play` and then fails, as `playCurrentTarget` can.
        var failsSettingTheRate = false
        /// iOS refusing to start the player right after the interruption (#2183): `play` throws.
        var failsPlay = false
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { playing = true }
        func play(targetId: String, from charOffset: Int) throws { self.charOffset = charOffset; playing = true }
        func play(targetId: String, fromMediaTimeMs t: Int) throws {
            if failsPlay { throw SessionKitError.invalidCommandForState("play") }
            mediaTimeMs = t; playing = true
        }
        func setPlaybackRate(_ rate: Double) throws {
            if failsSettingTheRate { throw SessionKitError.invalidCommandForState("setPlaybackRate") }
        }
        func pause() throws { resume.cancelAutomaticResume(); playing = false }
        func currentCharOffset() -> Int? { charOffset }
        func currentMediaTimeMs() -> Int? { mediaTimeMs }
        func currentPlaybackPosition() -> PlaybackPosition? {
            if let mediaTimeMs { return PlaybackPosition(mediaTimeMs: mediaTimeMs, durationMs: 4_740_000, anchorConfidence: .mediaTime) }
            return charOffset.map { PlaybackPosition(textStart: $0, textEnd: $0 + 1, anchorConfidence: .textRange) }
        }

        /// Siri (or a call) begins: the client pauses itself, arms the resume, and the engine is told.
        func systemInterruptionBegins() {
            let wasPlaying = playing
            resume.began(.interruption, wasPlaying: wasPlaying)
            playing = false
        }
        /// The interruption ends with iOS saying audio may start again. True when the client asks to resume.
        func systemInterruptionEnds() -> Bool {
            resume.ended(InterruptionEnd(rawOptions: InterruptionEnd.audioMayStartBit))
        }
    }

    private final class Recorder: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    private func rig(item: Item) throws -> (engine: SessionEngine, client: Client) {
        let client = Client()
        client.mediaTimeMs = item.id == episode.id ? 600_000 : nil
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: client, recorder: Recorder())
        _ = try engine.startSession(itemId: item.id)
        return (engine, client)
    }

    /// What the app does when the client reports `.began`: reconcile the engine with the pause the client applied.
    private func siriPausesIt(_ rig: (engine: SessionEngine, client: Client)) throws {
        rig.client.systemInterruptionBegins()
        _ = try rig.engine.reconcileSystemInitiatedPause()
        XCTAssertEqual(rig.engine.snapshot.status, .paused)
        XCTAssertTrue(rig.client.resume.isArmed, "the interruption armed an automatic resume")
    }

    // MARK: Done when 1: a Margin added while Siri is open leaves the resume armed

    func testAWrittenMarginSavedWhileSiriIsOpenStillResumesAPodcastWhenSiriCloses() throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)

        let capture = try rig.engine.beginWrittenInterjection()
        XCTAssertFalse(capture.wasPlaying, "Siri had already paused it")
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")

        XCTAssertTrue(rig.client.systemInterruptionEnds(), "Siri closing resumes the podcast")
    }

    func testAWrittenMarginSavedWhileSiriIsOpenStillResumesTextWhenSiriCloses() throws {
        let rig = try rig(item: article)
        try siriPausesIt(rig)

        let capture = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")

        XCTAssertTrue(rig.client.systemInterruptionEnds(), "Siri closing resumes the reading")
    }

    func testCancellingAWrittenMarginWhileSiriIsOpenStillResumesWhenSiriCloses() throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)

        let capture = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.cancelWrittenInterjection(captureId: capture.id)

        XCTAssertTrue(rig.client.systemInterruptionEnds())
    }

    func testStartingARecordingWhileSiriIsOpenStillResumesWhenSiriCloses() throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)

        _ = try rig.engine.beginInterjection()

        XCTAssertTrue(rig.client.systemInterruptionEnds())
    }

    // MARK: Done when 2: the listener's own pause still wins

    func testAWrittenMarginAfterTheListenersOwnPauseDoesNotResumeByItself() throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)
        _ = try rig.engine.pause() // the listener taps Pause while Siri is open

        let capture = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")

        XCTAssertFalse(rig.client.systemInterruptionEnds(), "the listener's Pause cancelled the automatic resume")
    }

    func testAWrittenMarginOnAPlainListenerPauseDoesNotResumeByItself() throws {
        let rig = try rig(item: episode)
        _ = try rig.engine.pause()

        let capture = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")

        XCTAssertFalse(rig.client.systemInterruptionEnds())
    }

    // MARK: Must not break: the in-app flow

    func testAWrittenMarginOnAPlayingItemStillPausesAndResumesOnSave() throws {
        let rig = try rig(item: episode)
        XCTAssertTrue(rig.client.playing)

        let capture = try rig.engine.beginWrittenInterjection()
        XCTAssertTrue(capture.wasPlaying)
        XCTAssertFalse(rig.client.playing, "it pauses on the tap")

        let snapshot = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")
        XCTAssertTrue(rig.client.playing, "and plays again on Save")
        XCTAssertTrue(snapshot.status.isPlaybackActive)
    }

    // MARK: Siri closes while the written Margin is still open

    func testSiriClosingBeforeSaveDefersTheResumeAndSavePlaysTheItem() throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)
        let capture = try rig.engine.beginWrittenInterjection()

        XCTAssertTrue(rig.client.systemInterruptionEnds(), "iOS says the item may resume")
        XCTAssertTrue(rig.engine.deferResumeToWrittenCapture(), "a Margin is open: the resume waits, it does not throw")
        XCTAssertFalse(rig.client.playing, "nothing plays under the open Margin")

        let snapshot = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")
        XCTAssertTrue(rig.client.playing, "Save plays the item")
        XCTAssertTrue(snapshot.status.isPlaybackActive)
    }

    func testSiriClosingBeforeCancelDefersTheResumeAndCancelPlaysTheItem() throws {
        let rig = try rig(item: article)
        try siriPausesIt(rig)
        let capture = try rig.engine.beginWrittenInterjection()

        XCTAssertTrue(rig.engine.deferResumeToWrittenCapture())
        let snapshot = try rig.engine.cancelWrittenInterjection(captureId: capture.id)

        XCTAssertTrue(rig.client.playing)
        XCTAssertTrue(snapshot.status.isPlaybackActive)
    }

    func testNothingIsDeferredWhenNoMarginIsOpen() throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)

        XCTAssertFalse(rig.engine.deferResumeToWrittenCapture(), "the caller resumes now")
        let snapshot = try rig.engine.resumePlaybackAfterInterruption()
        XCTAssertTrue(snapshot.status.isPlaybackActive)
    }

    func testADeferredResumeDoesNotOutliveItsMargin() throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)
        let first = try rig.engine.beginWrittenInterjection()
        XCTAssertTrue(rig.engine.deferResumeToWrittenCapture())
        _ = try rig.engine.saveWrittenInterjection(captureId: first.id, text: "One")
        _ = try rig.engine.pause() // the listener pauses

        let second = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.saveWrittenInterjection(captureId: second.id, text: "Two")

        XCTAssertFalse(rig.client.playing, "the first Margin's deferred resume is spent")
    }

    // MARK: A resume retry already running when the written Margin opens (#4846)

    /// The app's retrier wired as `retryMediaResumeAfterInterruption` wires it: it is paused where it was, and a retry
    /// refused by an open Margin (`requireNavigationAllowed`) would throw.
    @MainActor
    private func retryResume(
        _ rig: (engine: SessionEngine, client: Client), handingOver: Bool, outcomes: @escaping @MainActor (InterruptionResumeRetrier.Outcome) -> Void
    ) async {
        let retrier = InterruptionResumeRetrier(delaysMs: [10, 20, 40], sleep: { _ in })
        struct Refused: Error {}
        let engine = rig.engine
        retrier.begin(
            after: Refused(),
            stillWaiting: { engine.snapshot.status == .paused && !engine.snapshot.isRecording },
            handOver: { handingOver && engine.deferResumeToWrittenCapture() },
            attempt: { _ = try engine.resumePlaybackAfterInterruption() },
            report: outcomes
        )
        await retrier.waitUntilIdle()
    }

    @MainActor
    func testARetryRunningWhenAWrittenMarginOpensDefersToItAndSavePlaysTheItem() async throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)
        let capture = try rig.engine.beginWrittenInterjection()

        var outcomes: [InterruptionResumeRetrier.Outcome] = []
        await retryResume(rig, handingOver: true) { outcomes.append($0) }

        XCTAssertEqual(outcomes, [.deferred(attempts: 0)], "no retry runs into the open Margin, no failure, no give-up")
        XCTAssertFalse(rig.client.playing, "nothing plays under the open Margin")
        let snapshot = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")
        XCTAssertTrue(rig.client.playing, "Save plays the item")
        XCTAssertTrue(snapshot.status.isPlaybackActive)
    }

    @MainActor
    func testARetryRunningWhenAWrittenMarginOpensDefersToItAndCancelPlaysTheItem() async throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)
        let capture = try rig.engine.beginWrittenInterjection()

        var outcomes: [InterruptionResumeRetrier.Outcome] = []
        await retryResume(rig, handingOver: true) { outcomes.append($0) }
        let snapshot = try rig.engine.cancelWrittenInterjection(captureId: capture.id)

        XCTAssertEqual(outcomes, [.deferred(attempts: 0)])
        XCTAssertTrue(rig.client.playing)
        XCTAssertTrue(snapshot.status.isPlaybackActive)
    }

    /// The regression: without the hand-over the retries ran into the open Margin and ended with `gaveUp`, the
    /// "Playback paused after the interruption. Tap Play to resume." warning shown while the listener typed.
    @MainActor
    func testWithoutTheHandOverTheRetriesRunIntoTheOpenMarginAndGiveUp() async throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)
        _ = try rig.engine.beginWrittenInterjection()

        var outcomes: [InterruptionResumeRetrier.Outcome] = []
        await retryResume(rig, handingOver: false) { outcomes.append($0) }

        guard case .gaveUp? = outcomes.last else { return XCTFail("\(outcomes)") }
    }

    /// The path the audit found: a long Siri pause, the first resume steps the source back and is then refused, and the
    /// listener opens a Margin during the retry delay. The Margin publishes the stepped-back place, so the app's
    /// "paused where it was" check no longer holds; the hand-over must still be made, with the app's real checks.
    @MainActor
    func testAMarginOpenedAfterARefusedResumeThatSteppedBackStillDefersToSave() async throws {
        let clock = ClockBox()
        let client = Client()
        let repository = InMemorySessionRepository(items: [episode.id: episode])
        let engine = SessionEngine(profile: profile, repository: repository, audio: client, recorder: Recorder(), now: { clock.date })
        _ = try engine.startSession(itemId: episode.id)
        _ = try engine.seekMedia(toMediaTimeMs: 600_000)
        let rig = (engine: engine, client: client)
        try siriPausesIt(rig)
        clock.date.addTimeInterval(60) // a pause long enough to step back 6 s

        // The first resume: the engine steps the session back, then iOS refuses the player.
        client.failsPlay = true
        XCTAssertThrowsError(try engine.resumePlaybackAfterInterruption())
        client.failsPlay = false
        let place = InterruptionRetryPlace(snapshot: engine.snapshot, engine: engine) // what the app's retry captures
        let pausedAtMs = engine.snapshot.currentMediaTimeMs

        let capture = try engine.beginWrittenInterjection()
        XCTAssertNotEqual(engine.snapshot.currentMediaTimeMs, pausedAtMs, "the open Margin publishes the stepped-back place")

        var outcomes: [InterruptionResumeRetrier.Outcome] = []
        await runRetry(engine, place: place) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.deferred(attempts: 0)])

        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")
        XCTAssertTrue(client.playing, "Save plays the item")
    }

    /// The audit's counter-case: the listener seeks while the retries run and then opens a Margin. The item is theirs, so
    /// the hand-over declines, the retries end as abandoned, and Save leaves it paused where they put it.
    @MainActor
    func testAListenerSeekFollowedByAMarginDoesNotHandTheItemBackToTheRetry() async throws {
        let clock = ClockBox()
        let client = Client()
        let repository = InMemorySessionRepository(items: [episode.id: episode])
        let engine = SessionEngine(profile: profile, repository: repository, audio: client, recorder: Recorder(), now: { clock.date })
        _ = try engine.startSession(itemId: episode.id)
        _ = try engine.seekMedia(toMediaTimeMs: 600_000)
        try siriPausesIt((engine: engine, client: client))
        clock.date.addTimeInterval(60)
        client.failsPlay = true
        XCTAssertThrowsError(try engine.resumePlaybackAfterInterruption())
        client.failsPlay = false
        let place = InterruptionRetryPlace(snapshot: engine.snapshot, engine: engine)

        _ = try engine.seekMedia(toMediaTimeMs: 1_200_000) // the listener moves it while it is paused
        client.playing = false
        let capture = try engine.beginWrittenInterjection()

        var outcomes: [InterruptionResumeRetrier.Outcome] = []
        await runRetry(engine, place: place) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.abandoned(attempts: 0)])

        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")
        XCTAssertFalse(client.playing, "the listener's own place is not played over")
    }

    /// The second audit: the listener's Play and then Pause before the player confirms leaves the item paused at exactly
    /// the stepped-back place, so a place check cannot see that they acted.
    @MainActor
    func testAListenersPlayAndPauseBeforeAMarginDoesNotHandTheItemBackToTheRetry() async throws {
        let clock = ClockBox()
        let client = Client()
        let repository = InMemorySessionRepository(items: [episode.id: episode])
        let engine = SessionEngine(profile: profile, repository: repository, audio: client, recorder: Recorder(), now: { clock.date })
        _ = try engine.startSession(itemId: episode.id)
        _ = try engine.seekMedia(toMediaTimeMs: 600_000)
        try siriPausesIt((engine: engine, client: client))
        clock.date.addTimeInterval(60)
        client.failsPlay = true
        XCTAssertThrowsError(try engine.resumePlaybackAfterInterruption())
        client.failsPlay = false
        let place = InterruptionRetryPlace(snapshot: engine.snapshot, engine: engine)

        _ = try engine.resumePlayback() // the listener taps Play ...
        _ = try engine.pause() // ... and Pause
        client.playing = false
        let capture = try engine.beginWrittenInterjection()

        XCTAssertFalse(place.mayHandOverToWrittenCapture(engine.snapshot), "the listener acted: the item is theirs")
        var outcomes: [InterruptionResumeRetrier.Outcome] = []
        await runRetry(engine, place: place) { outcomes.append($0) }
        XCTAssertFalse(outcomes.contains(.deferred(attempts: 0)))

        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")
        XCTAssertFalse(client.playing, "the listener's Pause is not played over")
    }

    func testTheRetrysOwnResumeAndTheSystemsPauseAreNotTheListenersTransport() throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)
        let epoch = rig.engine.listenerTransportEpoch
        rig.client.failsPlay = true
        XCTAssertThrowsError(try rig.engine.resumePlaybackAfterInterruption())
        rig.client.failsPlay = false
        XCTAssertEqual(rig.engine.listenerTransportEpoch, epoch, "neither the system's pause nor the retry's resume counts")
        _ = try rig.engine.pause()
        XCTAssertEqual(rig.engine.listenerTransportEpoch, epoch + 1, "the listener's own Pause does")
    }

    /// The retrier wired as `retryMediaResumeAfterInterruption` wires it, with the app's `InterruptionRetryPlace`.
    @MainActor
    private func runRetry(_ engine: SessionEngine, place: InterruptionRetryPlace, report: @escaping @MainActor (InterruptionResumeRetrier.Outcome) -> Void) async {
        struct Refused: Error {}
        let retrier = InterruptionResumeRetrier(delaysMs: [10], sleep: { _ in })
        retrier.begin(
            after: Refused(),
            stillWaiting: { place.stillWaiting(engine.snapshot) },
            handOver: { place.mayHandOverToWrittenCapture(engine.snapshot) && engine.deferResumeToWrittenCapture() },
            attempt: { _ = try engine.resumePlaybackAfterInterruption() },
            report: report
        )
        await retrier.waitUntilIdle()
    }

    private final class ClockBox { var date = Date(timeIntervalSince1970: 1_000_000) }

    @MainActor
    func testARetryWithNoMarginOpenStillResumesTheItem() async throws {
        let rig = try rig(item: episode)
        try siriPausesIt(rig)

        var outcomes: [InterruptionResumeRetrier.Outcome] = []
        await retryResume(rig, handingOver: true) { outcomes.append($0) }

        XCTAssertEqual(outcomes, [.resumed(attempt: 1)])
        XCTAssertTrue(rig.client.playing)
    }

    // MARK: The system's pause is forgotten once playback starts again

    func testAFailedSaveRestoreStillPausesASourceThatWasPlayingAfterALostRoute() throws {
        let rig = try rig(item: episode)
        // Headphones unplugged: the pause is reconciled, nothing is armed.
        rig.client.playing = false
        _ = try rig.engine.reconcileSystemInitiatedPause()
        // The listener starts it again by another route (not `resumePlayback`), then writes a Margin.
        _ = try rig.engine.playSourceFromBeginning()
        XCTAssertTrue(rig.client.playing)
        let capture = try rig.engine.beginWrittenInterjection()
        XCTAssertTrue(capture.wasPlaying)

        rig.client.failsSettingTheRate = true // Save's restart plays, then fails
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "Check this claim")

        XCTAssertFalse(rig.client.playing, "the catch leaves the transport paused, as its comment says")
        XCTAssertEqual(rig.engine.snapshot.status, .paused)
    }
}
