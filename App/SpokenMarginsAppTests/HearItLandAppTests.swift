import XCTest
import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

/// #4713 (the visible PR) and #4715: after a new listener saves a spoken Margin the app plays it back in place, then the
/// speech-recognition card shows. Each test records a Margin on the seeded item through the real model, with a recorder that
/// hands back a real file so the saved Margin has a voice to play. They run on `main-t3`, not per PR.
@MainActor
final class HearItLandAppTests: XCTestCase {
    private var priorOnboardingSteps: Any?
    private var priorTermsVersion: Any?
    private var priorTermsDate: Any?
    private var root: URL!
    private var originalOutcomeCue: MarginOutcomeCuePlaying!

    private final class SilentOutcomeCue: MarginOutcomeCuePlaying {
        func play(_ cue: MarginOutcomeCue) -> String { "skipped:test" }
        func stop() {}
    }

    private final class SilentReadyCue: MarginReadyCuePlaying {
        func playReadyCue() -> String { "skipped:test" }
    }

    /// Takes in audio and hands back a file that exists, so the saved Margin's voice resolves.
    private final class FileRecordingClient: RecordingClient {
        let fileURL: URL
        init(fileURL: URL) { self.fileURL = fileURL }
        func beginRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { fileURL.path }
        func cancelRecording() throws {}
        func captureReading() -> RecordingCaptureReading? { RecordingCaptureReading(recorderRunning: true, capturedMs: 5_000) }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        priorOnboardingSteps = UserDefaults.standard.object(forKey: Gate1AppModel.onboardingStepsKey)
        priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        SpokenMarginsTerms.recordAcceptance()
        originalOutcomeCue = MarginOutcomeCuePlayer.shared
        MarginOutcomeCuePlayer.shared = SilentOutcomeCue()
        root = FileManager.default.temporaryDirectory.appending(path: "hear-it-land-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HearItLandState.shared.reset()
    }

    override func tearDownWithError() throws {
        HearItLandState.shared.reset()
        MarginOutcomeCuePlayer.shared = originalOutcomeCue
        try? FileManager.default.removeItem(at: root)
        let restored: [(Any?, String)] = [
            (priorOnboardingSteps, Gate1AppModel.onboardingStepsKey),
            (priorTermsVersion, SpokenMarginsTerms.acceptanceVersionKey),
            (priorTermsDate, SpokenMarginsTerms.acceptanceDateKey),
        ]
        for (value, key) in restored {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try super.tearDownWithError()
    }

    /// A fresh-install model with the seeded item open and a spoken Margin recording on it. `sourcePaused` pauses the
    /// source first, as a listener who taps Add a Margin while paused does.
    private func recordingModel(sourcePaused: Bool = false, heardFirstMargin: Bool = false) throws -> Gate1AppModel {
        let voice = root.appending(path: "margin-\(UUID().uuidString).m4a")
        try Data(repeating: 0, count: 64).write(to: voice)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: FileRecordingClient(fileURL: voice))
        model.captureWatcher = MarginCaptureWatcher(autoPoll: false, readyCue: SilentReadyCue())
        model.resetAndSeed()
        model.resetOnboardingProgressForTesting()
        if heardFirstMargin { model.markOnboardingSteps([.heardFirstMargin]) }
        model.startItem(id: "item-pill")
        if sourcePaused { model.pause() }
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording, "precondition: the Margin is recording")
        return model
    }

    private func finish(_ model: Gate1AppModel) {
        model.finishInterjection()
        XCTAssertFalse(model.snapshot.isRecording, "precondition: the Margin saved")
    }

    // MARK: the Design's four

    /// A first spoken save on a playing source starts the Margin's own moment with the five-second lead-in, the source plays
    /// on under it, and when the voice ends the card's line goes and the event "first Margin heard" is recorded.
    func testHearItLandPlaysAndResumes() throws {
        let model = try recordingModel()
        defer { model.endMarginMoment(); model.pause() }
        finish(model)

        let moment = try XCTUnwrap(model.marginMoment, "the saved Margin plays back in place")
        XCTAssertEqual(model.diagnostics["hearItLand"], "playBack")
        XCTAssertEqual(moment.unplayed, [moment.target], "only the new Margin: nothing keeps the card after the voice")
        XCTAssertLessThanOrEqual(moment.startMediaTimeMs, moment.target.mediaTimeMs, "the run-up starts before the Margin's place")
        XCTAssertEqual(model.hearItLandRun(forMomentTarget: moment.target.marginId), .hearItLand)
        XCTAssertTrue(model.snapshot.status.isPlaybackActive, "the source plays on (#1538)")
        XCTAssertFalse(model.isOnboardingStepComplete(.heardFirstMargin), "not heard until the voice ends")

        model.marginMomentVoiceEnded(moment.target, itemId: moment.itemId, reachedEnd: true)

        XCTAssertEqual(model.hearItLandRun(forMomentTarget: moment.target.marginId), .moment, "the lead-in line goes with the voice")
        XCTAssertNotNil(HearItLandState.shared.aftermath.playbackEndedAt)
        XCTAssertTrue(model.isOnboardingStepComplete(.heardFirstMargin), "the playback reaching its end is the event (#4711)")
    }

    /// "Save & resume" asks the source to play, so a spoken first save from a paused source plays back too (Default 2).
    func testPausedSpokenSavePlaysBack() throws {
        let model = try recordingModel(sourcePaused: true)
        defer { model.endMarginMoment(); model.pause() }
        finish(model)

        XCTAssertNotNil(model.marginMoment)
        XCTAssertEqual(model.diagnostics["hearItLand"], "playBack")
    }

    /// An upgrade marks "first Margin heard" done (#4711), so a returning listener never gets the playback.
    func testReturningNeverPlaysBack() throws {
        let model = try recordingModel(heardFirstMargin: true)
        defer { model.endMarginMoment(); model.pause() }
        finish(model)

        XCTAssertNil(model.marginMoment)
        XCTAssertNil(model.diagnostics["hearItLand"])
        XCTAssertNil(HearItLandState.shared.aftermath.playbackEndedAt)
    }

    /// A Margin saved over a held voice (#1672) leaves that voice to play on, so it gets no playback. Setting up a held
    /// voice needs the voice players, so this drives the model's decision and its save-end call with the held flag on.
    func testHeldVoiceGetsNoPlayback() throws {
        let model = try recordingModel()
        defer { model.endMarginMoment(); model.pause() }
        finish(model)
        model.endMarginMoment()
        HearItLandState.shared.reset()

        XCTAssertFalse(model.hearItLandWillPlayBack(hadSavedMarginBefore: false, heldVoice: true))
        XCTAssertTrue(model.hearItLandWillPlayBack(hadSavedMarginBefore: false, heldVoice: false), "the same save without a held voice does")
        model.hearItLandAfterSpokenSave(willPlayBack: false, savedId: nil)
        XCTAssertNil(model.marginMoment, "no playback starts over a held voice")
    }

    // MARK: the playback, then the ask

    /// A save while the speech card is owed: the playback runs first, and the card shows when its voice ends.
    func testSaveWhileTheSpeechCardIsOwedPlaysBackThenShowsTheCard() throws {
        let speech = SpeechAskController.shared
        try XCTSkipUnless(SpeechRecognitionAccess.state == .notDetermined, "iOS has already answered Speech Recognition on this simulator")
        try XCTSkipUnless(speech.ask.answer == .unanswered && speech.cardSurface == nil, "an earlier test in this process already answered or armed the card")
        let model = try recordingModel()
        defer { model.endMarginMoment(); model.pause() }
        finish(model)

        let moment = try XCTUnwrap(model.marginMoment, "the playback runs first")
        XCTAssertNil(speech.cardSurface, "the card waits for the playback")
        XCTAssertTrue(speech.isOutstanding, "but it is owed")

        model.marginMomentVoiceEnded(moment.target, itemId: moment.itemId, reachedEnd: true)

        XCTAssertEqual(speech.cardSurface, .now, "then the card shows")
    }

    /// A playback cancelled before its voice ends lets the card show, and leaves no hear-it-land line for a later
    /// "Play this moment" of that Margin.
    func testACancelledPlaybackLetsTheCardShowAndLeavesNoLine() throws {
        let model = try recordingModel()
        defer { model.endMarginMoment(); model.pause() }
        finish(model)
        let moment = try XCTUnwrap(model.marginMoment)
        XCTAssertEqual(model.hearItLandRun(forMomentTarget: moment.target.marginId), .hearItLand)

        model.endMarginMoment()

        XCTAssertEqual(model.hearItLandRun(forMomentTarget: moment.target.marginId), .moment)
    }
}
