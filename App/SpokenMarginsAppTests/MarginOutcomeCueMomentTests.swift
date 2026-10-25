import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The sound for how a spoken Margin ended (#1977): each fails when its `MarginOutcomeCuePlayer.shared.play`
/// line is removed or moved, and a written Margin, which has no recording to describe, plays nothing.
@MainActor
final class MarginOutcomeCueMomentTests: XCTestCase {
    private final class RecordingPlayer: MarginOutcomeCuePlaying {
        var played: [MarginOutcomeCue] = []
        var stops = 0
        func play(_ cue: MarginOutcomeCue) -> String { played.append(cue); return "played" }
        func stop() { stops += 1 }
    }

    /// A recorder that says whether its end turned the audio session off, and can take in a dead microphone's 22 ms.
    private final class SessionRecorder: RecordingClient {
        var releasesSession = false
        var reading: RecordingCaptureReading?
        var onRestart: () -> Void = {}
        func beginRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { audioRef ?? "interjections/outcome-cue.m4a" }
        func cancelRecording() throws {}
        func captureReading() -> RecordingCaptureReading? { reading }
        func restartCapture() throws { onRestart() }
        func releasedAudioSessionAtEnd() -> Bool { releasesSession }
    }

    private final class SilentReadyCue: MarginReadyCuePlaying {
        func playReadyCue() -> String { "skipped:test" }
    }

    private var original: MarginOutcomeCuePlaying!
    private var player: RecordingPlayer!
    private var priorTerms: [Any?] = []
    private let termsKeys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]

    override func setUp() async throws {
        original = MarginOutcomeCuePlayer.shared
        player = RecordingPlayer()
        MarginOutcomeCuePlayer.shared = player
        priorTerms = termsKeys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDown() async throws {
        MarginOutcomeCuePlayer.shared = original
        for (key, value) in zip(termsKeys, priorTerms) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func model(recorder: RecordingClient = NoopRecordingClient()) -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        return model
    }

    func testFinishingARecordingPlaysExactlyOneSavedCue() {
        let model = model()
        model.beginInterjection()
        player.played.removeAll()
        model.finishInterjection()
        XCTAssertEqual(player.played.count, 1, "one ending, one sound")
        XCTAssertTrue([MarginOutcomeCue.saved, .savedMaybeCut].contains(player.played[0]))
        XCTAssertEqual(model.diagnostics["outcomeCue"], "played")
    }

    func testCancellingAndWritingPlayNoOutcomeCue() {
        let model = model()
        model.beginInterjection()
        model.cancelInterjection()
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "A thought.")
        XCTAssertEqual(player.played, [])
    }

    func testADeadMicrophoneSoundsUntilItRecoversOrTheRecordingEnds() {
        let model = model()
        model.captureHealthChanged(.notCapturing(.noAudioAfterStart), restarts: 1)
        XCTAssertEqual(player.played, [.micStopped])
        let stopsBefore = player.stops
        model.captureHealthChanged(.capturing, restarts: 1)
        XCTAssertEqual(player.stops, stopsBefore + 1, "recovery ends the cue")
        let stopsAfterRecovery = player.stops
        model.endCaptureWatch()
        XCTAssertEqual(player.stops, stopsAfterRecovery + 1, "so does the end of the recording")
    }

    /// The audit on 3b0bbe8: with "Mix with other apps" on, the recorder turns the session off at the end so an
    /// audiobook resumes. A saved cue played then turned the non-mixing session back on and kept the audiobook silent.
    func testNoCuePlaysOnceTheRecorderHasHandedTheSessionBack() {
        let recorder = SessionRecorder()
        let model = model(recorder: recorder)
        model.beginInterjection()
        recorder.releasesSession = true
        player.played.removeAll()
        model.finishInterjection()
        XCTAssertEqual(player.played, [], "the cue would take the session back from the other app")
        XCTAssertEqual(model.diagnostics["outcomeCue"], "skipped:session_released")
    }

    /// The same audit: Try again starts the new recorder inside `retry()`, so a microphone cue still sounding
    /// opened the new recording. It has to end before the restart.
    func testTryAgainEndsTheMicrophoneCueBeforeTheNewRecorderStarts() {
        let recorder = SessionRecorder()
        var nowMs = 0
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder)
        model.captureWatcher = MarginCaptureWatcher(autoPoll: false, readyCue: SilentReadyCue(), nowMs: { nowMs })
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        model.beginInterjection()
        recorder.reading = RecordingCaptureReading(recorderRunning: true, capturedMs: 22)
        for _ in 0..<40 {
            nowMs += 250
            model.captureWatcher.tick()
        }
        XCTAssertEqual(player.played.last, .micStopped, "the dead microphone is sounding")
        XCTAssertTrue(model.canRetryMicrophone)
        let stopsBefore = player.stops
        var stopsAtRestart: Int?
        recorder.onRestart = { [player] in stopsAtRestart = player?.stops }
        model.retryMicrophone()
        XCTAssertEqual(stopsAtRestart, stopsBefore + 1, "the cue ended before the new recorder started")
    }
}
