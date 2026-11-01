import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #937: the recording screen said "Recording" over a recorder that took in 22 ms of audio in 34 seconds,
/// and the empty file was saved as a Margin. The screen follows what the recorder has taken in.
@MainActor
final class MarginCaptureHealthTests: XCTestCase {
    // A fresh simulator has never accepted the Terms, so the default voice holds text playback behind the
    // Terms sheet, `startItem` plays nothing and `beginInterjection` is refused. Run alone on a fresh
    // simulator, every test here failed that way (lane report pr1301-r38057340698). Accept them before the
    // model is made (it reads them at init) and put the earlier answer back afterwards, so order doesn't matter.
    private static let termsKeys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]
    private var priorTermsDefaults: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        priorTermsDefaults = [:]
        for key in Self.termsKeys {
            priorTermsDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDownWithError() throws {
        for key in Self.termsKeys {
            if let value = priorTermsDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try super.tearDownWithError()
    }

    /// A recorder that accepts its start, as the phone's did, and then takes in only what the test lets it.
    private final class ScriptedRecordingClient: RecordingClient, RecordingInterruptionReporting {
        var onInterruption: (@Sendable (_ event: MarginRecordingInterruptionEvent, _ recordedSeconds: TimeInterval?) -> Void)?
        /// What the recorder reports as audio taken in. The phone's said 22 and stayed there.
        var capturedMs: Int
        /// Audio grows by the time that passes, as a working microphone's does.
        var growsWithTime = false
        /// After a restart the new recorder hears the microphone.
        var healthyAfterRestart = false
        var restartFails = false
        /// The client refuses to delete a file that, once stopped, turns out to hold this much audio.
        var refusesRestartBecauseFileHoldsMs: Int?
        /// The recorder died after taking in `capturedMs`. A stopped AVAudioRecorder reads 0 afterwards.
        var stopped = false
        /// The recorder stopped but, like `SystemRecordingClient`, still reports what it took in.
        var stoppedButReports = false
        /// The stopped recorder's file is still being measured, or would not open: its length is unknown.
        var durationUnknown = false
        private(set) var restartCount = 0
        private(set) var finishCount = 0
        private(set) var cancelCount = 0
        /// What the watcher did around the ready cue (#1594), in order: "pause", "cue", "resume:<seconds>".
        var readyCueEvents: [String] = []

        init(capturedMs: Int) { self.capturedMs = capturedMs }

        func beginRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String {
            finishCount += 1
            return audioRef ?? "interjections/scripted.m4a"
        }
        func cancelRecording() throws { cancelCount += 1 }
        func pauseForReadyCue() { readyCueEvents.append("pause") }
        func resumeAfterReadyCue(after seconds: TimeInterval) { readyCueEvents.append("resume:\(seconds)") }
        func captureReading() -> RecordingCaptureReading? {
            stopped
                ? RecordingCaptureReading(recorderRunning: false, capturedMs: 0)
                : RecordingCaptureReading(
                    recorderRunning: !stoppedButReports,
                    capturedMs: capturedMs,
                    durationKnown: !durationUnknown
                )
        }
        func restartCapture() throws {
            restartCount += 1
            if let held = refusesRestartBecauseFileHoldsMs {
                capturedMs = held
                throw SessionKitError.persistenceFailed("recording_has_audio")
            }
            if restartFails { throw SessionKitError.persistenceFailed("recording_failed") }
            if healthyAfterRestart {
                capturedMs = 0
                growsWithTime = true
            }
        }
    }

    /// A model recording against a scripted recorder, with a clock the test moves.
    @MainActor
    private final class Harness {
        let recorder: ScriptedRecordingClient
        let model: Gate1AppModel
        /// Whether the screen ever said Recording while the harness polled.
        private(set) var everShownAsCapturing = false
        private var nowMs = 0

        /// `startFromLiveActivity` begins the Margin with the Lock Screen / Live Activity command instead of the in-app button.
        init(recorder: ScriptedRecordingClient, startFromLiveActivity: Bool = false, readyCue: MarginReadyCuePlaying = MarginReadyCuePlayer()) {
            self.recorder = recorder
            model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder)
            let clock: () -> Int = { [unowned self] in self.nowMs }
            model.captureWatcher = MarginCaptureWatcher(autoPoll: false, readyCue: readyCue, nowMs: clock)
            model.resetAndSeed()
            model.startItem(id: "item-pill")
            if startFromLiveActivity {
                model.dispatchGate2CompactCommand(.beginInterjection)
            } else {
                model.pause()
                model.beginInterjection()
            }
        }

        /// Polls every 250 ms for `seconds`, as the app does while recording.
        func run(seconds: Int) {
            for _ in 0..<(seconds * 4) {
                nowMs += 250
                if recorder.growsWithTime { recorder.capturedMs += 250 }
                model.captureWatcher.tick()
                if model.recordingCaptureHealth == .capturing { everShownAsCapturing = true }
            }
        }
    }

    /// Counts the ready cues the watcher asks for (#1594).
    @MainActor
    private final class SpyReadyCue: MarginReadyCuePlaying {
        private(set) var cueCount = 0
        var result = "played"
        /// Where the cue notes that it sounded, so a test can see it came between the recorder's pause and resume.
        var recorder: ScriptedRecordingClient?
        func playReadyCue() -> String {
            cueCount += 1
            recorder?.readyCueEvents.append("cue")
            return result
        }
    }

    /// #1594: a slow start (Bluetooth) is silent until audio really arrives, then sounds the cue exactly once.
    func testTheReadyCueSoundsOnceAfterAudioArrivesAndNotBefore() {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        let cue = SpyReadyCue()
        cue.recorder = recorder
        let harness = Harness(recorder: recorder, readyCue: cue)

        harness.run(seconds: 1)
        XCTAssertEqual(cue.cueCount, 0, "the recorder accepted the start but has taken in nothing")
        XCTAssertEqual(recorder.readyCueEvents, [], "nothing is held still before the cue")
        XCTAssertEqual(harness.model.recordingCaptureHealth, .starting)

        recorder.capturedMs = 300
        recorder.growsWithTime = true
        harness.run(seconds: 3)
        XCTAssertEqual(harness.model.recordingCaptureHealth, .capturing)
        XCTAssertEqual(cue.cueCount, 1, "one cue however many polls follow")
        XCTAssertEqual(harness.model.diagnostics["lastVoiceCapture"]?.contains("readyCue=played"), true)
        XCTAssertEqual(
            recorder.readyCueEvents,
            ["pause", "cue", "resume:\(MarginReadyCueHold.seconds)"],
            "the recorder is held still for the cue, so the speaker never reaches the saved Margin, and listens again once it is over"
        )
    }

    /// A cue that did not sound has nothing to keep out of the file, so the recorder listens again at once.
    func testTheRecorderListensAgainAtOnceWhenTheCueDidNotSound() {
        let recorder = ScriptedRecordingClient(capturedMs: 300)
        recorder.growsWithTime = true
        let cue = SpyReadyCue()
        cue.result = "skipped:session_not_recording"
        cue.recorder = recorder
        let harness = Harness(recorder: recorder, readyCue: cue)

        harness.run(seconds: 3)

        XCTAssertEqual(cue.cueCount, 1)
        XCTAssertEqual(recorder.readyCueEvents, ["pause", "cue", "resume:0.0"])
    }

    func testNoReadyCueWhenTheMicrophoneTakesInNothing() {
        let cue = SpyReadyCue()
        let recorder = ScriptedRecordingClient(capturedMs: 22)
        let harness = Harness(recorder: recorder, readyCue: cue)

        harness.run(seconds: 10)

        XCTAssertEqual(cue.cueCount, 0, "a failed start must not say the microphone is ready")
        XCTAssertEqual(recorder.readyCueEvents, [], "and must not hold the recorder still")
    }

    func testNoReadyCueWhenTheMarginIsCancelledBeforeAudioArrives() {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        let cue = SpyReadyCue()
        let harness = Harness(recorder: recorder, readyCue: cue)
        harness.run(seconds: 1)

        harness.model.cancelInterjection()
        recorder.capturedMs = 400
        harness.run(seconds: 2)

        XCTAssertEqual(cue.cueCount, 0)
        XCTAssertEqual(recorder.readyCueEvents, [])
    }

    func testARecorderThatTakesInNothingIsNeverShownAsRecordingAndIsTriedAgain() {
        let harness = Harness(recorder: ScriptedRecordingClient(capturedMs: 22))
        let model = harness.model
        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertEqual(model.recordingCaptureHealth, .starting)

        harness.run(seconds: 10)

        XCTAssertFalse(harness.everShownAsCapturing, "22 ms of audio must never read as Recording")
        XCTAssertEqual(harness.recorder.restartCount, MarginCaptureTimings.automaticRestarts)
        guard case .notCapturing = model.recordingCaptureHealth else {
            return XCTFail("expected the screen to say the microphone isn't recording, got \(model.recordingCaptureHealth)")
        }
        XCTAssertEqual(model.lastError?.contains("microphone isn't recording"), true)
    }

    func testSavingARecordingThatTookInNothingSavesNoMarginAndSaysSo() {
        let harness = Harness(recorder: ScriptedRecordingClient(capturedMs: 22))
        harness.run(seconds: 10)

        harness.model.finishInterjection()

        XCTAssertFalse(harness.model.snapshot.isRecording)
        XCTAssertEqual(harness.recorder.finishCount, 0, "an empty voice must not be saved as a Margin")
        XCTAssertEqual(harness.recorder.cancelCount, 1)
        XCTAssertEqual(harness.model.lastError?.hasPrefix("Nothing was recorded"), true)
        XCTAssertEqual(harness.model.recordingCaptureHealth, .capturing, "the state resets for the next Margin")
    }

    /// #771 audit P2: a call after ten seconds on the clock, with a microphone that took in 22 ms, must not
    /// save an empty voice as a Margin. The interruption path asks the watcher, as Save does. (Ten seconds,
    /// because each automatic restart resets the supervisor's clock and it judges only after 1.5 s on it.)
    func testACallDuringARecordingThatTookInNothingSavesNoMargin() async throws {
        let harness = Harness(recorder: ScriptedRecordingClient(capturedMs: 22))
        harness.run(seconds: 10)
        let marginCount = harness.model.selectedItem.interjections.count
        // What the phone does: iOS stops the recorder, and its file has not been measured yet.
        harness.recorder.stoppedButReports = true
        harness.recorder.durationUnknown = true

        harness.recorder.onInterruption?(.interruptionBegan, 10)
        for _ in 0..<50 where harness.model.snapshot.isRecording { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertFalse(harness.model.snapshot.isRecording)
        XCTAssertEqual(harness.recorder.finishCount, 0, "an empty voice must not be saved as a Margin")
        XCTAssertEqual(harness.recorder.cancelCount, 1)
        XCTAssertEqual(harness.model.selectedItem.interjections.count, marginCount)
        XCTAssertEqual(harness.model.snapshot.status, .paused, "the source still waits through the call")
        XCTAssertNil(harness.model.diagnostics["lastMarginCutShort"])
        XCTAssertEqual(harness.model.diagnostics["lastVoiceCapture"]?.contains("outcome=discard_empty"), true)
        XCTAssertEqual(harness.model.statusMessage.contains("hadn't picked up any sound"), true)
    }

    /// #771 audit P2: a recording that did take in speech is still kept, and its end-of-recording line is written.
    func testACallDuringARecordingWithSpeechSavesItAndWritesTheCaptureLine() async throws {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder)
        harness.run(seconds: 5)
        let marginCount = harness.model.selectedItem.interjections.count
        recorder.stoppedButReports = true
        recorder.durationUnknown = true

        recorder.onInterruption?(.interruptionBegan, 5)
        for _ in 0..<50 where harness.model.snapshot.isRecording { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertFalse(harness.model.snapshot.isRecording)
        XCTAssertEqual(recorder.finishCount, 1)
        XCTAssertEqual(recorder.cancelCount, 0)
        await harness.model.settleItemReload() // the item detail reloads off the main thread after the save (#2505)
        XCTAssertEqual(harness.model.selectedItem.interjections.count, marginCount + 1)
        XCTAssertEqual(harness.model.diagnostics["lastVoiceCapture"]?.contains("outcome=save_cut_short;"), true)
    }

    func testARestartThatWorksShowsRecordingOnceAudioArrives() {
        let recorder = ScriptedRecordingClient(capturedMs: 22)
        recorder.healthyAfterRestart = true
        let harness = Harness(recorder: recorder)
        XCTAssertEqual(harness.model.recordingCaptureHealth, .starting)

        harness.run(seconds: 4)

        XCTAssertEqual(recorder.restartCount, 1)
        XCTAssertEqual(harness.model.recordingCaptureHealth, .capturing)
        XCTAssertNil(harness.model.lastError)
    }

    func testARecordingWithAudioIsSavedAsAMargin() {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder)
        harness.run(seconds: 10)
        XCTAssertEqual(harness.model.recordingCaptureHealth, .capturing)

        harness.model.finishInterjection()

        XCTAssertFalse(harness.model.snapshot.isRecording)
        XCTAssertEqual(recorder.finishCount, 1)
        XCTAssertEqual(recorder.cancelCount, 0)
    }

    /// #1291 APO-03: a double tap on Save & resume reaches `finishInterjection()` twice. The UI test that
    /// double-taps Save never counted what was saved, and `Gate1FlowUITests` runs nowhere, so the count is
    /// checked here. The seeded item may already have Margins, so it counts from before the recording.
    func testADoubleTapOnSaveSavesExactlyOneMargin() {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder)
        let model = harness.model
        model.refreshMarginRows()
        let before = model.marginRows.count
        harness.run(seconds: 10)
        XCTAssertTrue(model.snapshot.isRecording, "precondition: the Margin is recording")

        model.finishInterjection()
        model.finishInterjection()

        model.refreshMarginRows()
        XCTAssertEqual(model.marginRows.count, before + 1, "a double tap on Save saves exactly one Margin")
        XCTAssertEqual(recorder.finishCount, 1, "the recorder is finished once")
        XCTAssertEqual(recorder.cancelCount, 0, "the second tap does not discard or cancel anything")
        XCTAssertFalse(model.snapshot.isRecording, "the second tap does not start or keep a recording")
        XCTAssertNil(model.lastError, "the second tap is ignored, not reported as a failure")
    }

    func testTryAgainRestartsTheRecorderAfterAFailure() {
        let recorder = ScriptedRecordingClient(capturedMs: 22)
        let harness = Harness(recorder: recorder)
        harness.run(seconds: 10)
        let restartsBefore = recorder.restartCount
        recorder.healthyAfterRestart = true

        harness.model.retryMicrophone()

        XCTAssertEqual(recorder.restartCount, restartsBefore + 1)
        XCTAssertEqual(harness.model.recordingCaptureHealth, .starting)
        harness.run(seconds: 1)
        XCTAssertEqual(harness.model.recordingCaptureHealth, .capturing)
    }

    func testTryAgainIsNotOfferedOnceTheRecordingHoldsSpeech() {
        // Three seconds of speech, then the microphone goes quiet. Try again would delete those three seconds.
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder)
        harness.run(seconds: 3)
        recorder.growsWithTime = false
        harness.run(seconds: 6)
        guard case .notCapturing = harness.model.recordingCaptureHealth else {
            return XCTFail("expected not capturing, got \(harness.model.recordingCaptureHealth)")
        }
        XCTAssertTrue(harness.model.recordingHasKeepableAudio)
        XCTAssertFalse(harness.model.canRetryMicrophone, "the screen offers Save, not Try again")

        harness.model.retryMicrophone()

        XCTAssertEqual(recorder.restartCount, 0, "a restart deletes the recording")
        XCTAssertTrue(harness.model.snapshot.isRecording)
        harness.model.finishInterjection()
        XCTAssertEqual(recorder.finishCount, 1, "what was said is saved")
        XCTAssertEqual(recorder.cancelCount, 0)
        XCTAssertEqual(harness.model.statusMessage.hasPrefix("Margin saved, but part of it may be missing"), true)
    }

    func testARecorderThatDiesAfterSpeechIsNotRestartedAndItsSpeechIsSaved() {
        // The real recorder reads 0 once it stops. The ten seconds before that are still in the file.
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder)
        harness.run(seconds: 10)
        recorder.stopped = true
        harness.run(seconds: 20)

        XCTAssertEqual(recorder.restartCount, 0, "a restart would delete the ten seconds")
        XCTAssertTrue(harness.model.recordingHasKeepableAudio)
        harness.model.finishInterjection()
        XCTAssertEqual(recorder.finishCount, 1)
        XCTAssertEqual(recorder.cancelCount, 0, "it is not discarded as empty")
        XCTAssertEqual(harness.model.statusMessage.hasPrefix("Margin saved, but part of it may be missing"), true)
    }

    // MARK: Lock Screen and Live Activity commands (audit P2 on #939)

    func testAMarginStartedFromTheLiveActivityIsWatchedAndNeverShownAsRecording() {
        let harness = Harness(recorder: ScriptedRecordingClient(capturedMs: 22), startFromLiveActivity: true)
        XCTAssertTrue(harness.model.snapshot.isRecording)
        XCTAssertEqual(harness.model.recordingCaptureHealth, .starting)

        harness.run(seconds: 10)

        XCTAssertFalse(harness.everShownAsCapturing, "22 ms of audio must never read as Recording, from any start")
        XCTAssertEqual(harness.recorder.restartCount, MarginCaptureTimings.automaticRestarts)
        guard case .notCapturing = harness.model.recordingCaptureHealth else {
            return XCTFail("expected not capturing, got \(harness.model.recordingCaptureHealth)")
        }
    }

    func testFinishingAnEmptyRecordingFromTheLiveActivitySavesNoMargin() {
        let harness = Harness(recorder: ScriptedRecordingClient(capturedMs: 22), startFromLiveActivity: true)
        harness.run(seconds: 10)

        harness.model.dispatchGate2CompactCommand(.finishInterjection)

        XCTAssertFalse(harness.model.snapshot.isRecording)
        XCTAssertEqual(harness.recorder.finishCount, 0, "the Live Activity must not save an empty voice either")
        XCTAssertEqual(harness.recorder.cancelCount, 1)
        XCTAssertEqual(harness.model.lastError?.hasPrefix("Nothing was recorded"), true)
        XCTAssertEqual(harness.model.selectedItem.interjections.count, 0)
    }

    func testFinishingARecordingWithSpeechFromTheLiveActivitySavesIt() {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder, startFromLiveActivity: true)
        harness.run(seconds: 10)

        harness.model.dispatchGate2CompactCommand(.finishInterjection)

        XCTAssertFalse(harness.model.snapshot.isRecording)
        XCTAssertEqual(recorder.finishCount, 1)
        XCTAssertEqual(recorder.cancelCount, 0)
        XCTAssertEqual(harness.model.selectedItem.interjections.count, 1)
    }

    func testFinishingACutShortRecordingFromTheLiveActivitySavesItAndSaysPartMayBeMissing() {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder, startFromLiveActivity: true)
        harness.run(seconds: 3)
        recorder.growsWithTime = false
        harness.run(seconds: 7)

        harness.model.dispatchGate2CompactCommand(.finishInterjection)

        XCTAssertEqual(recorder.finishCount, 1)
        XCTAssertEqual(harness.model.statusMessage.hasPrefix("Margin saved, but part of it may be missing"), true)
    }

    // MARK: Final capture numbers (audit P2 on #939)

    func testASavedMarginLeavesTheFinalCaptureNumbers() {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder)
        harness.run(seconds: 10)

        harness.model.finishInterjection()

        let summary = harness.model.diagnostics["lastVoiceCapture"] ?? ""
        XCTAssertTrue(summary.contains("outcome=save"), summary)
        XCTAssertTrue(summary.contains("wallMs=10000"), "time on the clock, not the startup reading: \(summary)")
        XCTAssertTrue(summary.contains("watchedCapturedMs=10000"), summary)
        XCTAssertTrue(summary.contains("restarts=0"), summary)
        XCTAssertTrue(summary.contains("health=capturing"), summary)
    }

    func testACancelledMarginLeavesTheFinalCaptureNumbers() {
        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let harness = Harness(recorder: recorder)
        harness.run(seconds: 6)

        harness.model.cancelInterjection()

        let summary = harness.model.diagnostics["lastVoiceCapture"] ?? ""
        XCTAssertTrue(summary.contains("outcome=cancelled"), summary)
        XCTAssertTrue(summary.contains("wallMs=6000"), summary)
    }

    func testADiscardedEmptyMarginIsLoggedAsDiscardedNotCancelled() {
        let harness = Harness(recorder: ScriptedRecordingClient(capturedMs: 22))
        harness.run(seconds: 10)

        harness.model.finishInterjection()

        let summary = harness.model.diagnostics["lastVoiceCapture"] ?? ""
        XCTAssertTrue(summary.contains("outcome=discard_empty"), summary)
        XCTAssertTrue(summary.contains("restarts=2"), summary)
    }

    // MARK: Audit round 2 on #939

    func testTryAgainReadsTheRecorderAgainAndRefusesWhenSpeechArrivedSinceTheLastPoll() {
        let recorder = ScriptedRecordingClient(capturedMs: 22)
        recorder.restartFails = true
        let harness = Harness(recorder: recorder)
        harness.run(seconds: 3)
        XCTAssertEqual(recorder.restartCount, 1, "the one automatic restart failed")
        XCTAssertTrue(harness.model.canRetryMicrophone, "as of the last poll nothing is worth keeping")
        // Speech reached the file after that poll, and the recorder then stopped. Nobody has polled since.
        recorder.capturedMs = 5_000
        recorder.stoppedButReports = true
        recorder.restartFails = false

        harness.model.retryMicrophone()

        XCTAssertEqual(recorder.restartCount, 1, "a restart would have deleted five seconds of speech")
        XCTAssertFalse(harness.model.canRetryMicrophone)
        XCTAssertTrue(harness.model.recordingHasKeepableAudio)
        XCTAssertEqual(harness.model.lastError?.contains("kept if you tap Save"), true)
    }

    func testARestartTheClientRefusesBecauseTheFileHoldsAudioLeavesTheAudioToSave() {
        let recorder = ScriptedRecordingClient(capturedMs: 22)
        recorder.refusesRestartBecauseFileHoldsMs = 4_000
        let harness = Harness(recorder: recorder)

        harness.run(seconds: 6)

        XCTAssertEqual(recorder.restartCount, 1, "refused once and not retried by itself")
        XCTAssertTrue(harness.model.recordingHasKeepableAudio, "the four seconds are now known")
        XCTAssertFalse(harness.model.canRetryMicrophone)
        XCTAssertEqual(harness.model.lastError?.contains("kept if you tap Save"), true)
        harness.model.finishInterjection()
        XCTAssertEqual(recorder.finishCount, 1, "Save keeps what was said")
        XCTAssertEqual(recorder.cancelCount, 0)
    }

    func testAStoppedRecorderWhoseFileCannotBeMeasuredIsKeptAndSavedNeverDiscarded() {
        // Audit round 3 on #939: an unreadable file is unknown, not empty. Nothing restarts or deletes it.
        let recorder = ScriptedRecordingClient(capturedMs: 100)
        recorder.stoppedButReports = true
        recorder.durationUnknown = true
        let harness = Harness(recorder: recorder)

        harness.run(seconds: 6)

        XCTAssertEqual(recorder.restartCount, 0, "no restart over a file that may hold speech")
        XCTAssertTrue(harness.model.recordingHasKeepableAudio)
        XCTAssertFalse(harness.model.canRetryMicrophone)
        harness.model.retryMicrophone()
        XCTAssertEqual(recorder.restartCount, 0)
        harness.model.finishInterjection()
        XCTAssertEqual(recorder.finishCount, 1, "Save keeps it")
        XCTAssertEqual(recorder.cancelCount, 0, "and does not cancel it as empty")
        XCTAssertEqual(harness.model.statusMessage.hasPrefix("Margin saved, but part of it may be missing"), true)
    }

    func testAMeasurementThatResolvesUnderTheLineReplacesTheKeptMessageWithTryAgain() {
        // #1041: after retries are used up, a pending measurement is "unknown, keep". When it lands under 250 ms
        // the health and restart count don't change, but the words and Try again must.
        let recorder = ScriptedRecordingClient(capturedMs: 22)
        recorder.stoppedButReports = true
        recorder.durationUnknown = true
        recorder.restartFails = true
        let harness = Harness(recorder: recorder)

        harness.run(seconds: 3)

        XCTAssertTrue(harness.model.recordingHasKeepableAudio)
        XCTAssertFalse(harness.model.canRetryMicrophone)
        XCTAssertEqual(harness.model.lastError?.contains("kept if you tap Save"), true)

        recorder.durationUnknown = false
        harness.run(seconds: 1)

        XCTAssertFalse(harness.model.recordingHasKeepableAudio)
        XCTAssertTrue(harness.model.canRetryMicrophone)
        XCTAssertEqual(harness.model.lastError?.contains("Tap Try again"), true)
    }

    func testAShortRecordingThatStallsIsKeptBySaveAndNotDeletedByTryAgain() {
        // 500 ms is above the one keep threshold, so Try again and Save agree.
        let recorder = ScriptedRecordingClient(capturedMs: 500)
        let harness = Harness(recorder: recorder)

        harness.run(seconds: 8)

        XCTAssertEqual(recorder.restartCount, 0)
        XCTAssertFalse(harness.model.canRetryMicrophone)
        harness.model.retryMicrophone()
        XCTAssertEqual(recorder.restartCount, 0)
        harness.model.finishInterjection()
        XCTAssertEqual(recorder.finishCount, 1)
    }

    func testTheLiveActivityFollowsTheMicrophoneAndResetsWhenTheMarginEnds() {
        let harness = Harness(recorder: ScriptedRecordingClient(capturedMs: 22))
        let controller = harness.model.gate2CompactControls
        XCTAssertEqual(controller.microphone, .starting, "the card does not say REC while the microphone is starting")

        harness.run(seconds: 10)

        XCTAssertEqual(controller.microphone, .stopped, "and not while it has stopped")
        harness.model.finishInterjection()
        XCTAssertEqual(controller.microphone, .capturing, "the state resets for the next Margin")

        let recorder = ScriptedRecordingClient(capturedMs: 0)
        recorder.growsWithTime = true
        let healthy = Harness(recorder: recorder)
        healthy.run(seconds: 3)
        XCTAssertEqual(healthy.model.gate2CompactControls.microphone, .capturing)
    }

    func testARestartThatFailsLeavesTheScreenSayingSo() {
        let recorder = ScriptedRecordingClient(capturedMs: 22)
        recorder.restartFails = true
        let harness = Harness(recorder: recorder)

        harness.run(seconds: 10)

        XCTAssertEqual(recorder.restartCount, 1, "a failed restart is not retried by itself")
        guard case .notCapturing = harness.model.recordingCaptureHealth else {
            return XCTFail("expected not capturing, got \(harness.model.recordingCaptureHealth)")
        }
        XCTAssertNotNil(harness.model.lastError)
    }

    func testARecorderThatCannotTellKeepsRecordingAsBefore() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.captureWatcher = MarginCaptureWatcher(autoPoll: false, nowMs: { 0 })
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertEqual(model.recordingCaptureHealth, .capturing)

        model.finishInterjection()

        XCTAssertFalse(model.snapshot.isRecording)
    }
}
