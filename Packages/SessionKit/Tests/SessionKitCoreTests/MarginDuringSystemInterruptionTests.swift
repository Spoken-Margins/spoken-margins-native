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
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { playing = true }
        func play(targetId: String, from charOffset: Int) throws { self.charOffset = charOffset; playing = true }
        func play(targetId: String, fromMediaTimeMs t: Int) throws { mediaTimeMs = t; playing = true }
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
