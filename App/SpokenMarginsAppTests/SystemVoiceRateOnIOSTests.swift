import AVFoundation
import XCTest
@testable import SessionKit

/// #221 lane: on the iOS simulator, the iOS voice at 1.5× read at the 1× pace. The rate table in
/// `SpeechRateRule` was measured on macOS voices; this renders real iOS speech and times it.
/// On failure the message carries the measured iOS curve, for recalibrating the table.
final class SystemVoiceRateOnIOSTests: XCTestCase {
    private let passage = "The listener picks a speed, and narration should play at that speed whichever voice is speaking. This passage is long enough to time the speaking rate without the silences at either end dominating the result."

    func testIOSVoiceIsHeardAtTheChosenSpeed() throws {
        guard let voice = AVSpeechSynthesisVoice(language: "en-US") else {
            throw XCTSkip("No en-US system voice in this runtime")
        }
        try SystemVoiceRuntime.skipIfStalledEarlier()
        let normal = try renderedSeconds(rate: SpeechRateRule.systemSpeechRate(forMultiplier: 1), voice: voice)
        let slow = try renderedSeconds(rate: SpeechRateRule.systemSpeechRate(forMultiplier: 0.75), voice: voice)
        let fast = try renderedSeconds(rate: SpeechRateRule.systemSpeechRate(forMultiplier: 1.5), voice: voice)
        let faster = try renderedSeconds(rate: SpeechRateRule.systemSpeechRate(forMultiplier: 2), voice: voice)
        var curve: [String] = []
        for rate: Float in [0.1, 0.3, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.8, 1.0] {
            curve.append(String(format: "%.2f:%.2f", rate, normal / (try renderedSeconds(rate: rate, voice: voice))))
        }
        let report = "voice \(voice.identifier); heard 0.75×=\(normal / slow), 1.5×=\(normal / fast), 2×=\(normal / faster); iOS curve (AVSpeech rate:heard multiple) \(curve.joined(separator: " "))"
        print(report)
        XCTAssertEqual(normal / fast, 1.5, accuracy: 1.5 * 0.25, report)
        XCTAssertEqual(normal / slow, 0.75, accuracy: 0.75 * 0.25, report)
        XCTAssertEqual(normal / faster, 2, accuracy: 2 * 0.25, report)
    }

    private func renderedSeconds(rate: Float, voice: AVSpeechSynthesisVoice) throws -> Double {
        let utterance = AVSpeechUtterance(string: passage)
        utterance.voice = voice
        utterance.rate = rate
        let synthesizer = AVSpeechSynthesizer()
        // #768: the synthesizer goes on calling into the main queue after its end of stream; releasing it
        // then is the #1230 crash, which surfaced in the system-voice tests that run next.
        SystemVoiceRuntime.keep(synthesizer)
        let tally = RenderTally()
        let write = Write(synthesizer: synthesizer, utterance: utterance)
        // The write can block its caller while the speech service loads (#1230), so it starts off the
        // test's thread and the wait below keeps its timeout.
        SystemVoiceRuntime.writeQueue.async { write.start(into: tally) }
        // #768: `wait(for:)` recorded a failure on timeout before the skip below could run, so a write that
        // never answered failed this test and left the next audio engine start in the process to abort.
        // XCTWaiter only reports the timeout; the stall is recorded so the session test skips too.
        guard XCTWaiter().wait(for: [tally.finished], timeout: 60) == .completed else {
            SystemVoiceRuntime.recordStall("rendering at rate \(rate) delivered no end of speech in 60 s")
            throw XCTSkip("The system voice stopped answering (rendering at rate \(rate), 60 s); #768")
        }
        let (frames, sampleRate) = tally.result
        guard sampleRate > 0 else { throw XCTSkip("The system voice rendered no audio in this runtime") }
        return frames / sampleRate
    }

    private final class Write: @unchecked Sendable {
        let synthesizer: AVSpeechSynthesizer
        let utterance: AVSpeechUtterance
        init(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance) {
            self.synthesizer = synthesizer
            self.utterance = utterance
        }
        func start(into tally: RenderTally) { synthesizer.write(utterance) { tally.receive($0) } }
    }

    /// Frames from one write. Not the test case's own expectation: a write that answers after the wait
    /// gave up must not fulfil one.
    private final class RenderTally: @unchecked Sendable {
        let finished = XCTestExpectation(description: "rendered to the end of speech")
        private let lock = NSLock()
        private var frames: Double = 0
        private var sampleRate: Double = 0
        private var ended = false
        var result: (Double, Double) { lock.withLock { (frames, sampleRate) } }
        func receive(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let endsNow: Bool = lock.withLock {
                if pcm.frameLength == 0 {
                    defer { ended = true }
                    return !ended
                }
                if !ended {
                    frames += Double(pcm.frameLength)
                    sampleRate = pcm.format.sampleRate
                }
                return false
            }
            if endsNow { finished.fulfill() }
        }
    }
}
