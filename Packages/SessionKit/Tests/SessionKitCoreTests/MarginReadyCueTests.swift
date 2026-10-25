import XCTest
@testable import SessionKit

/// #1594: a short cue tells the listener the microphone is really capturing. It sounds once per recording,
/// and never before the recorder has taken in audio.
final class MarginReadyCueTests: XCTestCase {
    /// Polls a real supervisor the way `MarginCaptureWatcher.tick()` does and counts the cues the gate allows.
    private struct Recording {
        var supervisor = MarginCaptureSupervisor(beganAtMs: 0)
        var gate = MarginReadyCueGate()
        var cues: [Int] = []

        mutating func poll(at ms: Int, _ reading: RecordingCaptureReading?) {
            _ = supervisor.observe(reading, nowMs: ms)
            if gate.shouldCue(health: supervisor.health, capturedMs: supervisor.capturedMs) { cues.append(ms) }
        }
    }

    private func reading(running: Bool = true, capturedMs: Int) -> RecordingCaptureReading {
        RecordingCaptureReading(recorderRunning: running, capturedMs: capturedMs)
    }

    func testNoCueWhileTheStartIsStillSlowThenOneWhenAudioArrives() {
        var recording = Recording()
        // A Bluetooth start: the recorder accepted the start, and no audio arrives for over a second.
        for ms in stride(from: 0, through: 1_500, by: 250) { recording.poll(at: ms, reading(capturedMs: 0)) }
        XCTAssertEqual(recording.supervisor.health, .starting)
        XCTAssertEqual(recording.cues, [], "accepting the start is not capture")
        recording.poll(at: 1_750, reading(capturedMs: 40))
        XCTAssertEqual(recording.cues, [], "under the first-audio line")
        recording.poll(at: 2_000, reading(capturedMs: MarginCaptureTimings.firstAudioMs))
        XCTAssertEqual(recording.cues, [2_000])
    }

    func testRepeatedCapturingPollsCueOnce() {
        var recording = Recording()
        for (index, ms) in stride(from: 250, through: 3_000, by: 250).enumerated() {
            recording.poll(at: ms, reading(capturedMs: 120 + index * 250))
        }
        XCTAssertEqual(recording.supervisor.health, .capturing)
        XCTAssertEqual(recording.cues.count, 1)
    }

    func testAStartThatNeverCapturesGetsNoCue() {
        var recording = Recording()
        for ms in stride(from: 0, through: 6_000, by: 250) { recording.poll(at: ms, reading(capturedMs: 22)) }
        guard case .notCapturing = recording.supervisor.health else { return XCTFail("should be stalled") }
        XCTAssertEqual(recording.cues, [])
    }

    func testAStoppedRecorderGetsNoCue() {
        var recording = Recording()
        for ms in stride(from: 0, through: 500, by: 250) { recording.poll(at: ms, reading(running: false, capturedMs: 0)) }
        XCTAssertEqual(recording.cues, [])
    }

    func testAStallAfterTheCueAndARecoveryDoNotCueAgain() {
        var recording = Recording()
        recording.poll(at: 250, reading(capturedMs: 300))
        XCTAssertEqual(recording.cues, [250])
        // The audio stops growing, then the supervisor restarts and the new recorder captures.
        for ms in stride(from: 500, through: 3_000, by: 250) { recording.poll(at: ms, reading(capturedMs: 300)) }
        guard case .notCapturing = recording.supervisor.health else { return XCTFail("should be stalled") }
        recording.supervisor.captureRestarted(nowMs: 3_000)
        recording.poll(at: 3_250, reading(capturedMs: 400))
        XCTAssertEqual(recording.supervisor.health, .capturing)
        XCTAssertEqual(recording.cues, [250], "one cue per recording")
    }

    func testARestartAfterAFailedStartCuesOnceWhenItCaptures() {
        var recording = Recording()
        for ms in stride(from: 0, through: 2_250, by: 250) { recording.poll(at: ms, reading(capturedMs: 0)) }
        guard case .notCapturing = recording.supervisor.health else { return XCTFail("should be stalled") }
        XCTAssertEqual(recording.cues, [])
        recording.supervisor.captureRestarted(nowMs: 2_250)
        recording.poll(at: 2_500, reading(capturedMs: 0))
        XCTAssertEqual(recording.cues, [])
        recording.poll(at: 2_750, reading(capturedMs: 250))
        recording.poll(at: 3_000, reading(capturedMs: 500))
        XCTAssertEqual(recording.cues, [2_750])
    }

    func testARecorderThatCannotReadAudioNeverCues() {
        // A nil reading (a test double, the watch) counts as capturing but says nothing about audio.
        var recording = Recording()
        for ms in stride(from: 0, through: 2_000, by: 250) { recording.poll(at: ms, nil) }
        XCTAssertEqual(recording.supervisor.health, .capturing)
        XCTAssertEqual(recording.cues, [])
    }

    func testCueIsAShortSoftWaveThatFadesInAndOut() {
        let data = MarginReadyCue.wavData()
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self) + String(decoding: data[8..<16], as: UTF8.self), "RIFFWAVEfmt ")
        let seconds = Double(data.count - 44) / 2 / Double(MarginReadyCue.sampleRate)
        XCTAssertEqual(seconds, MarginReadyCue.totalSeconds, accuracy: 0.01)
        XCTAssertLessThan(seconds, 0.25, "short enough to be over before the first words")
        let samples = stride(from: 44, to: data.count, by: 2).map { Int16(littleEndian: Int16(data[$0]) | Int16(data[$0 + 1]) << 8) }
        let loudest = Double(samples.map { abs(Int($0)) }.max() ?? 0) / Double(Int16.max)
        XCTAssertEqual(loudest, MarginReadyCue.peak, accuracy: 0.01)
        XCTAssertLessThan(abs(Int(samples.first ?? 1)), 200, "fades in, no click")
        XCTAssertLessThan(abs(Int(samples.last ?? 1)), 200, "fades out, no click")
    }

    func testCueDiffersFromTheOtherCues() {
        XCTAssertNotEqual(MarginReadyCue.wavData(), PlaybackStartChime.wavData())
        XCTAssertNotEqual(MarginReadyCue.wavData(), SharedMarginCue.doubleChimeWAVData())
    }

    func testTheRecorderIsHeldForTheWholeCueAndATail() {
        XCTAssertGreaterThanOrEqual(MarginReadyCueHold.seconds, MarginReadyCue.totalSeconds + MarginReadyCueHold.tailSeconds)
        XCTAssertGreaterThan(MarginReadyCueHold.tailSeconds, 0, "the speaker and microphone delays outlast the cue itself")
        XCTAssertLessThan(MarginReadyCueHold.seconds, 0.3, "a listener who speaks right after the cue loses nothing")
    }

    // #2594: the cue is about 10 dB quieter with headphones on, and the speaker is untouched.

    func testHeadphonesGetAQuieterCueAndTheSpeakerKeepsItsLevel() {
        XCTAssertEqual(MarginReadyCue.volume(for: .speaker), 0.6, "the speaker level the owner called right is unchanged")
        XCTAssertLessThan(MarginReadyCue.volume(for: .headphones), MarginReadyCue.volume(for: .speaker) / 2, "clearly lower")
        XCTAssertGreaterThan(MarginReadyCue.volume(for: .headphones), 0.05, "still audible")
    }

    func testEveryPortOnTheEarsIsHeadphonesAndEveryOtherRouteIsTheSpeaker() {
        for port in ["BluetoothHFP", "BluetoothA2DPOutput", "BluetoothLE", "Headphones", "USBAudio"] {
            XCTAssertEqual(ReadyCueOutputRoute(outputPortTypes: [port]), .headphones, port)
        }
        for port in ["Speaker", "Receiver", "AirPlay", "CarAudio", "LineOut", "HDMI", "SomethingNew"] {
            XCTAssertEqual(ReadyCueOutputRoute(outputPortTypes: [port]), .speaker, port)
        }
        XCTAssertEqual(ReadyCueOutputRoute(outputPortTypes: []), .speaker, "no route known: the old level")
        XCTAssertEqual(ReadyCueOutputRoute(outputPortTypes: ["Speaker", "BluetoothA2DPOutput"]), .headphones, "any worn output wins")
    }
}
