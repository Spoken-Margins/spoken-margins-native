import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #937: the recording screen said "Recording" over a recorder that took in 22 ms of audio in 34 seconds,
/// and the empty file was saved as a Margin. The screen follows what the recorder has taken in.
@MainActor
final class MarginCaptureHealthTests: XCTestCase {
    /// A recorder that accepts its start, as the phone's did, and then takes in only what the test lets it.
    private final class ScriptedRecordingClient: RecordingClient {
        /// What the recorder reports as audio taken in. The phone's said 22 and stayed there.
        var capturedMs: Int
        /// Audio grows by the time that passes, as a working microphone's does.
        var growsWithTime = false
        /// After a restart the new recorder hears the microphone.
        var healthyAfterRestart = false
        var restartFails = false
        private(set) var restartCount = 0
        private(set) var finishCount = 0
        private(set) var cancelCount = 0

        init(capturedMs: Int) { self.capturedMs = capturedMs }

        func beginRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String {
            finishCount += 1
            return audioRef ?? "interjections/scripted.m4a"
        }
        func cancelRecording() throws { cancelCount += 1 }
        func captureReading() -> RecordingCaptureReading? {
            RecordingCaptureReading(recorderRunning: true, capturedMs: capturedMs)
        }
        func restartCapture() throws {
            restartCount += 1
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

        init(recorder: ScriptedRecordingClient) {
            self.recorder = recorder
            model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder)
            let clock: () -> Int = { [unowned self] in self.nowMs }
            model.captureWatcher = MarginCaptureWatcher(autoPoll: false, nowMs: clock)
            model.resetAndSeed()
            model.startItem(id: "item-pill")
            model.pause()
            model.beginInterjection()
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
