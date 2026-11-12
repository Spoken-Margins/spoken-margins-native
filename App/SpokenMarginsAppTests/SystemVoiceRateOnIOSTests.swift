import AVFoundation
import XCTest
@testable import SessionKit

/// #221 lane: on the iOS simulator, the iOS voice at 1.5× read at the 1× pace. The rate table in
/// `SpeechRateRule` was measured on macOS voices; this renders real iOS speech and times it.
/// On failure the message carries the measured iOS curve, for recalibrating the table.
final class SystemVoiceRateOnIOSTests: XCTestCase {
    private let passage = "The listener picks a speed, and narration should play at that speed whichever voice is speaking. This passage is long enough to time the speaking rate without the silences at either end dominating the result."

    /// #4054: the test timed out at the plan's 2 minutes twice (2026-11-04, 2026-11-07), both times on a
    /// runner whose audio was overloaded (`HALC_ProxyIOContext ... skipping cycle due to overload`) while the
    /// speech service started cold. It passes in 11 s on a healthy runner. Two causes are removed here: the
    /// allowance is asked for in `setUp`, before the runner starts its clock, not inside the test body; and the
    /// ten extra renders that only build the failure report (the iOS rate curve) now happen only when a measured
    /// speed is outside its tolerance, so a passing run renders four passages, not fourteen.
    override func setUpWithError() throws {
        executionTimeAllowance = 180
    }

    func testIOSVoiceIsHeardAtTheChosenSpeed() throws {
        guard let voice = AVSpeechSynthesisVoice(language: "en-US") else {
            throw XCTSkip("No en-US system voice in this runtime")
        }
        try SystemVoiceRuntime.skipIfStalledEarlier()
        // #1230: the first write may wait minutes on the speech service loading; give it the cold-start
        // allowance so a slow start isn't read as a #768 stall.
        let normal = try renderedSeconds(rate: SpeechRateRule.systemSpeechRate(forMultiplier: 1), voice: voice,
                                         waiting: SystemVoiceRuntime.coldStartAllowance)
        let slow = try renderedSeconds(rate: SpeechRateRule.systemSpeechRate(forMultiplier: 0.75), voice: voice)
        let fast = try renderedSeconds(rate: SpeechRateRule.systemSpeechRate(forMultiplier: 1.5), voice: voice)
        let faster = try renderedSeconds(rate: SpeechRateRule.systemSpeechRate(forMultiplier: 2), voice: voice)
        let heard = (slow: normal / slow, fast: normal / fast, faster: normal / faster)
        if Self.isWithinTolerance(heard.fast, of: 1.5), Self.isWithinTolerance(heard.slow, of: 0.75),
           Self.isWithinTolerance(heard.faster, of: 2) {
            print("voice \(voice.identifier); heard 0.75×=\(heard.slow), 1.5×=\(heard.fast), 2×=\(heard.faster)")
            return
        }
        // Out of tolerance: only now render the measured iOS curve, for recalibrating the table.
        var curve: [String] = []
        for rate: Float in [0.1, 0.3, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.8, 1.0] {
            curve.append(String(format: "%.2f:%.2f", rate, normal / (try renderedSeconds(rate: rate, voice: voice))))
        }
        let report = "voice \(voice.identifier); heard 0.75×=\(heard.slow), 1.5×=\(heard.fast), 2×=\(heard.faster); iOS curve (AVSpeech rate:heard multiple) \(curve.joined(separator: " "))"
        print(report)
        XCTAssertEqual(heard.fast, 1.5, accuracy: 1.5 * Self.tolerance, report)
        XCTAssertEqual(heard.slow, 0.75, accuracy: 0.75 * Self.tolerance, report)
        XCTAssertEqual(heard.faster, 2, accuracy: 2 * Self.tolerance, report)
    }

    private static let tolerance = 0.25

    private static func isWithinTolerance(_ heard: Double, of expected: Double) -> Bool {
        abs(heard - expected) <= expected * tolerance
    }

    private func renderedSeconds(rate: Float, voice: AVSpeechSynthesisVoice, waiting: TimeInterval = 60) throws -> Double {
        let utterance = AVSpeechUtterance(string: passage)
        utterance.voice = voice
        utterance.rate = rate
        let listening = SystemVoiceRuntime.startWrite(utterance, offTheAppsSession: false)
        // #768: `wait(for:)` recorded a failure on timeout, so a write that never answered failed this test
        // and left the next audio engine start in the process to abort. XCTWaiter only reports the timeout;
        // a write that delivered nothing is recorded as a stall and skipped, and the session test skips too.
        let finished = XCTWaiter().wait(for: [listening.finished], timeout: waiting) == .completed
        let heard = listening.heard
        if finished, heard.frames == 0 { throw XCTSkip("The system voice rendered no audio in this runtime") }
        try SystemVoiceRuntime.requireAnswered(
            SystemVoiceRuntime.classify(heard, finished: finished, waited: waiting, what: "rendering at rate \(rate)"),
            from: listening)
        return heard.frames / heard.sampleRate
    }
}
