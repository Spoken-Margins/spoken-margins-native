import AVFoundation
import SessionKit
import XCTest
@testable import SessionKitAudio
@testable import SpokenMarginsApp

/// #2511: a Margin's tap switches the audio session for recording off the main thread before the recorder starts.
/// Each test fails if the model stops asking for the switch, starts the recorder before it is done, or leaves a
/// switched session behind when no recording comes.
@MainActor
final class RecordingSessionPreparationAppTests: XCTestCase {
    private final class PreparingRecorder: RecordingClient, RecordingSessionPreparing {
        var log: [String] = []
        var pendingStart: (@MainActor @Sendable () -> Void)?
        func prepareRecordingSession(then: @escaping @MainActor @Sendable () -> Void) {
            log.append("prepare")
            pendingStart = then
        }
        func abandonRecordingSessionPreparation() { log.append("abandon") }
        func beginRecording() throws { log.append("begin") }
        func finishRecording(audioRef: String?) throws -> String { audioRef ?? "interjections/prepared.m4a" }
        func cancelRecording() throws { log.append("cancel") }
        func captureReading() -> RecordingCaptureReading? { nil }
        func restartCapture() throws {}
        /// The preparation queue finishing: the recorder starts on the main thread.
        @MainActor func finishSwitch() {
            let start = pendingStart
            pendingStart = nil
            start?()
        }
    }

    private var priorTerms: [Any?] = []
    private let termsKeys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]

    override func setUp() async throws {
        priorTerms = termsKeys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDown() async throws {
        for (key, value) in zip(termsKeys, priorTerms) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func pausedModel(_ recorder: PreparingRecorder) -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        return model
    }

    func testWithNothingSoundingTheRecorderStartsOnlyAfterTheSessionSwitch() {
        let recorder = PreparingRecorder()
        let model = pausedModel(recorder)
        model.beginInterjection()
        XCTAssertEqual(recorder.log, ["prepare"], "the tap asks for the switch and returns without starting the recorder")
        XCTAssertFalse(model.snapshot.isRecording)
        recorder.finishSwitch()
        XCTAssertEqual(recorder.log, ["prepare", "begin"])
        XCTAssertTrue(model.snapshot.isRecording, "the Margin records once the switch is done")
    }

    func testCancelWhileTheSessionSwitchesLetsItGoAndStartsNothing() {
        let recorder = PreparingRecorder()
        let model = pausedModel(recorder)
        model.beginInterjection()
        model.cancelInterjection()
        XCTAssertEqual(recorder.log, ["prepare", "abandon"], "Cancel lets the switched session go")
        recorder.finishSwitch()
        XCTAssertFalse(recorder.log.contains("begin"), "a switch that finishes after Cancel starts no recording")
        XCTAssertFalse(model.snapshot.isRecording)
    }

    func testWritingInsteadWhileTheSessionSwitchesLetsItGo() {
        let recorder = PreparingRecorder()
        let model = pausedModel(recorder)
        model.beginInterjection()
        model.switchPendingVoiceCaptureToWrittenMargin()
        XCTAssertEqual(recorder.log, ["prepare", "abandon"])
        recorder.finishSwitch()
        XCTAssertFalse(recorder.log.contains("begin"))
    }

    /// Speech that is still playing is paused by the engine itself, just before the recorder; switching the session
    /// first would let the listener hear it move to the hands-free profile. So it keeps the old order.
    func testASourceStillPlayingKeepsTheSwitchInsideTheRecorderStart() {
        let recorder = PreparingRecorder()
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertTrue(model.snapshot.status.isPlaybackActive, "precondition: the seeded item is playing")
        model.beginInterjection()
        XCTAssertFalse(recorder.log.contains("prepare"))
        XCTAssertEqual(recorder.log, ["begin"])
        XCTAssertTrue(model.snapshot.isRecording)
    }

    /// #3633: `playAndRecord` drops AirPlay outputs unless it allows them, which moved a HomePod's playback to the phone
    /// speaker when the owner tapped record in the app. Both microphone choices keep AirPlay.
    func testRecordingSessionAllowsAirPlayForEveryMicrophoneChoice() {
        for choice in [RecordingInputChoice.headsetMicrophoneAllowed, .phoneMicrophoneKeepingA2DP] {
            XCTAssertTrue(SystemRecordingClient.recordingOptions(for: choice).contains(.allowAirPlay), "\(choice)")
        }
        XCTAssertTrue(SystemRecordingClient.recordingOptions(for: .headsetMicrophoneAllowed).contains(.allowBluetoothHFP))
        XCTAssertFalse(SystemRecordingClient.recordingOptions(for: .phoneMicrophoneKeepingA2DP).contains(.allowBluetoothHFP),
                       "the A2DP choice must keep leaving the hands-free profile out (#1506)")
    }

    /// #3633 audit: the option sets must be ones iOS accepts on a real `AVAudioSession`, and must read back as set, or
    /// `startRecorder` would redo `setCategory` on the main thread at every start and undo #2511. Only the HomePod
    /// itself can show that the route stays on AirPlay; this shows the sets are accepted and settle.
    func testTheRecordingSessionOptionsAreAcceptedByARealSessionAndReadBackAsSet() throws {
        let session = AVAudioSession.sharedInstance()
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        for choice in [RecordingInputChoice.headsetMicrophoneAllowed, .phoneMicrophoneKeepingA2DP] {
            let outcome = SystemRecordingClient.applyRecordingSession(for: choice)
            XCTAssertNil(outcome.failure, "\(choice): the session refused the recording options")
            XCTAssertTrue(outcome.applied, "\(choice)")
            XCTAssertEqual(
                SystemRecordingClient.currentConfiguration(session), SystemRecordingClient.recordingConfiguration(for: choice),
                "\(choice): the session must read back what was set"
            )
            XCTAssertFalse(
                AudioSessionConfiguration.needsCategoryChange(
                    current: SystemRecordingClient.currentConfiguration(session),
                    wanted: SystemRecordingClient.recordingConfiguration(for: choice)),
                "\(choice): a second preparation must find nothing to change"
            )
        }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: SystemSpokenNoteTakeRecorder.recordingOptions)
        XCTAssertTrue(session.categoryOptions.contains(.allowAirPlay), "the spoken-note take keeps AirPlay")
    }
}
