import Foundation
import XCTest
@testable import SessionKit

/// #937: the screen said "Recording" over a recorder that took in 22 ms of audio in 34 seconds.
/// The supervisor judges capture from what the recorder has taken in, never from its say-so.
final class MarginCaptureSupervisorTests: XCTestCase {
    private func reading(running: Bool = true, capturedMs: Int) -> RecordingCaptureReading {
        RecordingCaptureReading(recorderRunning: running, capturedMs: capturedMs)
    }

    /// Polls every 250 ms for `seconds`, with `capturedMs(atMs:)` as what the recorder reports. Carries
    /// out a restart the way the app does: a new recorder that reports from zero again.
    private struct Run {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        var healthByTick: [MarginCaptureSupervisor.Health] = []
        var restartTimes: [Int] = []
    }

    private func run(
        seconds: Int,
        running: @escaping (_ sinceStartMs: Int) -> Bool = { _ in true },
        capturedMs: @escaping (_ sinceStartMs: Int) -> Int
    ) -> Run {
        var result = Run()
        var recorderStartedAtMs = 0
        var nowMs = 0
        while nowMs <= seconds * 1_000 {
            let since = nowMs - recorderStartedAtMs
            let action = result.supervisor.observe(
                reading(running: running(since), capturedMs: capturedMs(since)),
                nowMs: nowMs
            )
            result.healthByTick.append(result.supervisor.health)
            if action == .restartCapture {
                result.restartTimes.append(nowMs)
                recorderStartedAtMs = nowMs
                result.supervisor.captureRestarted(nowMs: nowMs)
            }
            nowMs += 250
        }
        return result
    }

    // MARK: Health

    func testAudioFlowingIsCapturingAfterTheFirstAudio() {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.health, .starting)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 0), nowMs: 250), .none)
        XCTAssertEqual(supervisor.health, .starting, "a recorder that has taken in nothing yet is only starting")
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 240), nowMs: 500), .none)
        XCTAssertEqual(supervisor.health, .capturing)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 2_000), nowMs: 2_250), .none)
        XCTAssertEqual(supervisor.health, .capturing)
    }

    func testTheOwnersLogNeverCountsAsRecording() {
        // Build 30 on the phone: the recorder said it was running, and 30 to 34 seconds later the file held 22 ms.
        let result = run(seconds: 34, capturedMs: { _ in 22 })
        XCTAssertFalse(result.healthByTick.contains(.capturing), "22 ms of audio must never read as Recording")
        XCTAssertEqual(result.healthByTick.last, .notCapturing(.noAudioAfterStart))
    }

    func testARecorderThatNeverGetsAudioIsRestartedTwiceThenGivenUp() {
        let result = run(seconds: 30, capturedMs: { _ in 22 })
        XCTAssertEqual(result.restartTimes.count, MarginCaptureTimings.automaticRestarts)
        XCTAssertEqual(result.restartTimes, [2_000, 4_000], "each restart waits out a full start grace")
        XCTAssertEqual(result.supervisor.restarts, 2)
    }

    func testARestartThatGetsAudioRecovers() {
        // The first recorder is dead; the second one hears the microphone straight away.
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 22), nowMs: 2_000), .restartCapture)
        XCTAssertEqual(supervisor.health, .notCapturing(.noAudioAfterStart))
        supervisor.captureRestarted(nowMs: 2_000)
        XCTAssertEqual(supervisor.health, .starting)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 300), nowMs: 2_500), .none)
        XCTAssertEqual(supervisor.health, .capturing)
        XCTAssertEqual(supervisor.restarts, 1)
    }

    func testARestartedRecorderThatWorksStaysCapturingThroughTheRun() {
        // The first recorder reports 22 ms for ever; the second hears the microphone.
        var recorderStartedAtMs = 0
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        var health: [MarginCaptureSupervisor.Health] = []
        for nowMs in stride(from: 250, through: 12_000, by: 250) {
            let since = nowMs - recorderStartedAtMs
            let captured = recorderStartedAtMs == 0 ? 22 : since
            if supervisor.observe(reading(capturedMs: captured), nowMs: nowMs) == .restartCapture {
                recorderStartedAtMs = nowMs
                supervisor.captureRestarted(nowMs: nowMs)
            }
            health.append(supervisor.health)
        }
        XCTAssertEqual(supervisor.health, .capturing)
        XCTAssertEqual(supervisor.restarts, 1)
        XCTAssertFalse(health.prefix(7).contains(.capturing), "nothing reads as Recording until audio arrives")
    }

    func testAStoppedRecorderIsNotCapturingAtOnce() {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(reading(running: false, capturedMs: 0), nowMs: 250), .restartCapture)
        XCTAssertEqual(supervisor.health, .notCapturing(.recorderStopped))
    }

    func testAudioThatStopsGrowingIsStalledButItsAudioIsKept() {
        // Three seconds of real audio, then nothing. A restart would throw those three seconds away.
        let result = run(seconds: 12, capturedMs: { since in min(since, 3_000) })
        XCTAssertTrue(result.restartTimes.isEmpty)
        XCTAssertEqual(result.healthByTick.last, .notCapturing(.audioStalled))
        XCTAssertTrue(result.healthByTick.contains(.capturing), "it was capturing until the audio stopped")
    }

    func testARecorderThatStopsAfterRealAudioIsNotRestarted() {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 5_000), nowMs: 5_000), .none)
        XCTAssertEqual(supervisor.observe(reading(running: false, capturedMs: 5_000), nowMs: 5_250), .none)
        XCTAssertEqual(supervisor.health, .notCapturing(.recorderStopped))
    }

    func testAStoppedRecorderThatReadsZeroAfterRealAudioIsNotRestarted() {
        // A stopped AVAudioRecorder reports currentTime 0. The ten seconds it took in are still on disk,
        // and a restart would delete them (audit P1 on #939).
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 10_000), nowMs: 10_000), .none)
        XCTAssertEqual(supervisor.observe(reading(running: false, capturedMs: 0), nowMs: 10_250), .none)
        XCTAssertEqual(supervisor.health, .notCapturing(.recorderStopped))
        XCTAssertTrue(supervisor.hasKeepableAudio, "the audio taken in before the stop is still there to keep")
        XCTAssertEqual(supervisor.capturedMs, 10_000)
        XCTAssertEqual(supervisor.observe(reading(running: false, capturedMs: 0), nowMs: 12_000), .none, "and it stays kept")
    }

    func testSaveAndTryAgainShareOneKeepThreshold() {
        // Audit P1 on #939: Save kept from 250 ms but Try again protected audio only from 1 s, so a
        // 500 ms recording that stalled could be deleted by Try again while Save would have kept it.
        XCTAssertEqual(MarginCaptureTimings.keepAudioMs, 250)
        for capturedMs in [250, 500, 900, 1_000] {
            var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
            XCTAssertEqual(supervisor.observe(reading(capturedMs: capturedMs), nowMs: 500), .none)
            XCTAssertEqual(supervisor.observe(reading(capturedMs: capturedMs), nowMs: 4_000), .none, "stalled with \(capturedMs) ms: kept, not restarted")
            XCTAssertTrue(supervisor.hasKeepableAudio, "\(capturedMs) ms is worth keeping")
            XCTAssertNotEqual(
                supervisor.saveVerdict(reading: reading(capturedMs: capturedMs), nowMs: 4_000),
                .discardEmpty,
                "and Save keeps it too"
            )
        }
        var below = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(below.observe(reading(capturedMs: 249), nowMs: 500), .none)
        XCTAssertEqual(below.observe(reading(capturedMs: 249), nowMs: 4_000), .restartCapture, "under the threshold is still restarted")
        XCTAssertFalse(below.hasKeepableAudio)
        XCTAssertEqual(below.saveVerdict(reading: reading(capturedMs: 249), nowMs: 4_000), .discardEmpty)
    }

    func testARecorderThatCannotTellCountsAsRunning() {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(nil, nowMs: 250), .none)
        XCTAssertEqual(supervisor.health, .capturing, "test doubles and the watch behave as they did before the check")
    }

    func testAFailedRestartIsNotCapturingAndStopsRestarting() {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 0), nowMs: 2_000), .restartCapture)
        supervisor.restartFailed()
        XCTAssertEqual(supervisor.health, .notCapturing(.recorderStopped))
        XCTAssertEqual(supervisor.observe(reading(running: false, capturedMs: 0), nowMs: 2_250), .none)
        XCTAssertEqual(supervisor.health, .notCapturing(.recorderStopped))
    }

    func testTheListenerCanTryAgain() {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        for nowMs in stride(from: 250, through: 10_000, by: 250) {
            if supervisor.observe(reading(capturedMs: 22), nowMs: nowMs) == .restartCapture {
                supervisor.captureRestarted(nowMs: nowMs)
            }
        }
        XCTAssertEqual(supervisor.health, .notCapturing(.noAudioAfterStart))
        supervisor.listenerRetry(nowMs: 10_000)
        XCTAssertEqual(supervisor.health, .starting)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 0), nowMs: 12_000), .restartCapture, "one more restart is allowed")
    }

    // MARK: Saving

    func testNothingCapturedOverThirtyFourSecondsIsDiscardedNotSaved() {
        let supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.saveVerdict(reading: reading(capturedMs: 22), nowMs: 34_000), .discardEmpty)
    }

    func testAShortRecordingIsTooBriefToJudge() {
        let supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.saveVerdict(reading: reading(capturedMs: 0), nowMs: 1_000), .save)
    }

    func testARealMarginIsSaved() {
        let supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.saveVerdict(reading: reading(capturedMs: 11_900), nowMs: 12_000), .save)
        XCTAssertEqual(supervisor.saveVerdict(reading: reading(capturedMs: 2_000), nowMs: 2_100), .save)
    }

    func testARecordingThatStoppedEarlyIsSavedAndMarkedCutShort() {
        let supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.saveVerdict(reading: reading(running: false, capturedMs: 3_000), nowMs: 34_000), .saveCutShort)
    }

    func testARecordingThatStoppedAndReadsZeroIsStillSavedWithItsAudio() {
        // Ten seconds of speech, then the recorder stopped and reads 0. Save must keep what was said.
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 10_000), nowMs: 10_000), .none)
        XCTAssertEqual(supervisor.observe(reading(running: false, capturedMs: 0), nowMs: 10_250), .none)
        XCTAssertEqual(
            supervisor.saveVerdict(reading: reading(running: false, capturedMs: 0), nowMs: 34_000),
            .saveCutShort,
            "never discarded as empty, and the listener is told part of it may be missing"
        )
    }

    func testAStoppedRecordingWithOnlyAFewMillisecondsStillReadsAsEmpty() {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 22), nowMs: 250), .none)
        XCTAssertEqual(supervisor.saveVerdict(reading: reading(running: false, capturedMs: 0), nowMs: 34_000), .discardEmpty)
    }

    func testARecorderThatCannotTellIsAlwaysSaved() {
        let supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.saveVerdict(reading: nil, nowMs: 34_000), .save)
    }

    func testTheSaveVerdictJudgesTheCurrentRecorderAfterARestart() {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        XCTAssertEqual(supervisor.observe(reading(capturedMs: 0), nowMs: 2_000), .restartCapture)
        supervisor.captureRestarted(nowMs: 2_000)
        // The new recorder has run for one second: too brief to call it empty.
        XCTAssertEqual(supervisor.saveVerdict(reading: reading(capturedMs: 0), nowMs: 3_000), .save)
        XCTAssertEqual(supervisor.saveVerdict(reading: reading(capturedMs: 0), nowMs: 6_000), .discardEmpty)
    }
}
