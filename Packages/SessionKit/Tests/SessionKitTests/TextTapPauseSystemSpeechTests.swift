import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio
#if canImport(AVFoundation)
import AVFoundation

/// A Margin on text the synthesizer has read to its end before the progress tick saw it (#3928). The engine took the
/// end of the text for a place in progress, and Save resumed speech from there: "Something went wrong" and the recording
/// screen stayed up. The real system-speech client, with the synthesizer's callbacks delivered by the test.
final class TextTapPauseSystemSpeechTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online", displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ]
    )

    private let article = Item(
        id: "item-article", title: "Article", mediaType: "text",
        text: "First sentence. Second sentence. Third sentence.",
        externalReference: nil, status: "ready"
    )

    private final class Recorder: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    private struct Rig {
        let engine: SessionEngine
        let speech: SystemSpeechPlaybackClient
        let repository: InMemorySessionRepository
        var queued: () -> [(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance)]
    }

    private func makeRig() throws -> Rig {
        let speech = SystemSpeechPlaybackClient(voiceIdentifier: nil, speechRate: AVSpeechUtteranceDefaultSpeechRate)
        final class Box { var queued: [(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance)] = [] }
        let box = Box()
        speech.speakNarration = { box.queued.append(($0, $1)) } // nothing is spoken; the test delivers the callbacks
        let repository = InMemorySessionRepository(items: [article.id: article])
        let engine = SessionEngine(profile: profile, repository: repository, audio: speech, recorder: Recorder())
        _ = try engine.startSession(itemId: article.id)
        return Rig(engine: engine, speech: speech, repository: repository, queued: { box.queued })
    }

    /// Save keeps the Margin and leaves the finished item paused at its end, as a recap Margin does (#142).
    private func assertSavedOnFinishedText(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = try rig.engine.finishInterjection(audioRef: nil, resumesSource: true)
        XCTAssertFalse(saved.isRecording, file: file, line: line)
        XCTAssertEqual(saved.status, .paused, file: file, line: line)
        XCTAssertEqual(rig.engine.currentSession?.phase, .finished, file: file, line: line)
    }

    /// What the simulator's synthesizer does (inference): it runs the whole queue at once, so by the tap every
    /// utterance has started and finished and the client reports the end of the text as its place.
    private func finishEverySpokenUtteranceAtOnce(_ rig: Rig) throws {
        let queued = rig.queued()
        let synthesizer = try XCTUnwrap(queued.first?.synthesizer)
        for entry in queued {
            rig.speech.speechSynthesizer(synthesizer, didStart: entry.utterance)
            rig.speech.speechSynthesizer(synthesizer, didFinish: entry.utterance)
        }
    }

    /// The app's order since #2511: the tap pauses the text first, then the recorder starts, then Save.
    func testSaveAfterTheTapPausedTextTheSynthesizerAlreadyFinished() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)
        XCTAssertTrue(rig.engine.snapshot.status.isPlaybackActive, "no progress tick ran yet: the engine still says it plays")

        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())

        try assertSavedOnFinishedText(rig)
    }

    /// No tap pause (the order before #2511): the engine start reads the place and pauses.
    func testSaveWithoutTheTapPauseTheSynthesizerAlreadyFinished() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)

        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())

        try assertSavedOnFinishedText(rig)
    }

    /// The app's 0.5 s progress tick between the end of speech and the start: finished already, as before.
    func testSaveWithoutTheTapPauseAfterATick() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)
        _ = try rig.engine.syncPlaybackProgress(coalescingWrites: true)
        XCTAssertEqual(rig.engine.currentSession?.phase, .finished, "the tick marks the reading finished")

        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())

        try assertSavedOnFinishedText(rig)
    }

    /// Current order with a tick after the tap: the held place hides the completion from the tick.
    func testSaveAfterTheTapPauseAndATick() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.syncPlaybackProgress(coalescingWrites: true)

        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())

        try assertSavedOnFinishedText(rig)
    }

    /// Cancel on the same Margin leaves the finished item where it is instead of resuming speech from its end.
    func testCancelAfterTheTapPausedTextTheSynthesizerAlreadyFinished() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())

        let cancelled = try rig.engine.cancelInterjection(resumesSource: true)
        XCTAssertFalse(cancelled.isRecording)
        XCTAssertEqual(cancelled.status, .paused)
        XCTAssertEqual(rig.engine.currentSession?.phase, .finished)
    }

    /// A written Margin on the same text: Save keeps it and leaves the finished item paused.
    func testWrittenMarginSaveOnTextTheSynthesizerAlreadyFinished() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)
        let capture = try rig.engine.beginWrittenInterjection()

        let saved = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "A written note.")
        XCTAssertEqual(saved.status, .paused)
        XCTAssertEqual(rig.engine.currentSession?.phase, .finished)
    }

    /// #3930: "Go to this moment" on that written Margin. Its place is the end of the text, where nothing is left to
    /// read, so playing from it threw ("Could not play this Margin's position") and the listener stayed where they were.
    func testGoingToAWrittenMarginSavedAtTheEndOfFinishedText() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)
        let capture = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "A written note.")
        let sessionId = try XCTUnwrap(rig.engine.currentSession?.id)
        let margin = try XCTUnwrap(rig.repository.loadInterjections(sessionId: sessionId).first)
        XCTAssertEqual(margin.anchor.startChar, article.text?.count, "the Margin sits at the end of the text")

        let moment = try rig.engine.playInterjectionAnchor(margin)

        XCTAssertEqual(moment.itemId, article.id)
        XCTAssertEqual(moment.status, .paused, "the item opens at its end, as a completed session does")
        XCTAssertEqual(rig.engine.currentSession?.phase, .finished)
        XCTAssertEqual(rig.engine.currentSession?.completionPercent, 100)
    }

    /// The same tap on a Margin with text after it still starts speech there.
    func testGoingToAWrittenMarginWithTextAfterItStartsSpeech() throws {
        let rig = try makeRig()
        let capture = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "A written note.")
        let sessionId = try XCTUnwrap(rig.engine.currentSession?.id)
        let margin = try XCTUnwrap(rig.repository.loadInterjections(sessionId: sessionId).first)
        XCTAssertLessThan(margin.anchor.startChar, article.text?.count ?? 0)
        let queuedBefore = rig.queued().count

        let moment = try rig.engine.playInterjectionAnchor(margin)

        XCTAssertTrue(moment.status.isPlaybackActive)
        XCTAssertGreaterThan(rig.queued().count, queuedBefore, "speech was queued from the Margin's place")
    }

    /// Cancel on a written Margin on the same text leaves the finished item where it is.
    func testWrittenMarginCancelOnTextTheSynthesizerAlreadyFinished() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)
        let capture = try rig.engine.beginWrittenInterjection()

        let cancelled = try rig.engine.cancelWrittenInterjection(captureId: capture.id)
        XCTAssertEqual(cancelled.status, .paused)
        XCTAssertEqual(rig.engine.currentSession?.phase, .finished)
    }

    /// The client keeps its completion until a new start, so a listener who moved back after the end, while paused,
    /// anchors the Margin where they moved to, not at the end.
    func testMarginAfterMovingBackFromTheEndWhilePausedAnchorsWhereTheListenerIs() throws {
        let rig = try makeRig()
        try finishEverySpokenUtteranceAtOnce(rig)
        _ = try rig.engine.syncPlaybackProgress(coalescingWrites: true)
        XCTAssertEqual(rig.engine.currentSession?.phase, .finished)
        _ = try rig.engine.seekText(toCharOffset: 16)
        XCTAssertTrue(rig.speech.isPlaybackComplete(targetId: article.id), "the move back left the client's completion")
        XCTAssertNotEqual(rig.engine.currentSession?.phase, .finished)

        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())

        XCTAssertNotEqual(rig.engine.currentSession?.phase, .finished)
        XCTAssertLessThan(try XCTUnwrap(rig.engine.recordingAnchor).startChar, article.text?.count ?? 0)
    }
}
#endif
