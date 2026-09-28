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
        var frames: Double = 0
        var sampleRate: Double = 0
        var finished = false
        let done = expectation(description: "rendered at \(rate)")
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                if !finished { finished = true; done.fulfill() }
                return
            }
            frames += Double(pcm.frameLength)
            sampleRate = pcm.format.sampleRate
        }
        wait(for: [done], timeout: 60)
        guard sampleRate > 0 else { throw XCTSkip("The system voice rendered no audio in this runtime") }
        return frames / sampleRate
    }
}
