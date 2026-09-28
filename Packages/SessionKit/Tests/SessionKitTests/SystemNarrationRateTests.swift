import XCTest
@testable import SessionKit
@testable import SessionKitAudio
#if canImport(AVFoundation)
import AVFoundation
#endif

/// C2 M1 (#183): the iOS-voice fallback multiplied the Accessibility speaking rate by the app's
/// rate, and the app's rate itself mapped 1.75× to about 3× real speed.
final class SystemNarrationRateTests: XCTestCase {
    #if canImport(AVFoundation)
    func testFallbackNarrationNeverBorrowsTheAccessibilitySpeakingRate() throws {
        let defaults = UserDefaults.standard
        let priorRate = defaults.object(forKey: "speechRate")
        let priorVoice = defaults.object(forKey: "speechVoiceIdentifier")
        defer {
            defaults.set(priorRate, forKey: "speechRate")
            defaults.set(priorVoice, forKey: "speechVoiceIdentifier")
        }
        defaults.set(0.875, forKey: "speechRate") // the app's stored 1.75×
        defaults.removeObject(forKey: "speechVoiceIdentifier")

        // The Supertonic fallback uses this default client when no iOS voice is chosen.
        let client = SystemSpeechPlaybackClient()
        _ = try client.prepareSpeechText("Rate is one number.")
        let stored = try client.makeNarrationUtterance("Rate is one number.")
        XCTAssertFalse(stored.prefersAssistiveTechnologySettings)
        XCTAssertEqual(stored.rate, SpeechRateRule.systemSpeechRate(forMultiplier: 1.75), accuracy: 0.0001)

        try client.setPlaybackRate(1.25)
        let changed = try client.makeNarrationUtterance("Rate is one number.")
        XCTAssertFalse(changed.prefersAssistiveTechnologySettings)
        XCTAssertEqual(changed.rate, SpeechRateRule.systemSpeechRate(forMultiplier: 1.25), accuracy: 0.0001)
        XCTAssertEqual(client.currentPlaybackPosition()?.playbackRate ?? 1.25, 1.25, accuracy: 0.001)
    }

    func testChosenIOSVoiceSpeaksTheCalibratedRate() throws {
        let client = SystemSpeechPlaybackClient(voiceIdentifier: nil, speechRate: 0.375) // stored 0.75×
        let slow = try client.makeNarrationUtterance("Slower than normal.")
        XCTAssertEqual(slow.rate, SpeechRateRule.systemSpeechRate(forMultiplier: 0.75), accuracy: 0.0001)
        XCTAssertFalse(slow.prefersAssistiveTechnologySettings)
    }

    /// Real AVFoundation: renders the same passage at 1×, 0.75× and 1.5× and times it.
    func testNarrationIsHeardAtTheChosenSpeed() throws {
        guard let voice = AVSpeechSynthesisVoice(language: "en-US") else {
            throw XCTSkip("No en-US system voice on this host")
        }
        let passage = "The listener picks a speed, and narration should play at that speed whichever voice is speaking. This passage is long enough to time."
        func heardSeconds(multiplier: Double) throws -> Double {
            let client = SystemSpeechPlaybackClient(voiceIdentifier: voice.identifier, speechRate: 0.5)
            try client.setPlaybackRate(multiplier)
            let utterance = try client.makeNarrationUtterance(passage)
            return try renderedSeconds(utterance)
        }
        let normal = try heardSeconds(multiplier: 1)
        let slow = try heardSeconds(multiplier: 0.75)
        let fast = try heardSeconds(multiplier: 1.5)
        // Before this fix 1.5× was heard at about 2.5×, so a ±25% band still catches it.
        XCTAssertEqual(normal / fast, 1.5, accuracy: 1.5 * 0.25, "1.5× heard at \(normal / fast)×")
        XCTAssertEqual(normal / slow, 0.75, accuracy: 0.75 * 0.25, "0.75× heard at \(normal / slow)×")
    }

    private func renderedSeconds(_ utterance: AVSpeechUtterance) throws -> Double {
        let synthesizer = AVSpeechSynthesizer()
        var frames: Double = 0
        var sampleRate: Double = 0
        let finished = expectation(description: "rendered")
        var fulfilled = false
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                if !fulfilled { fulfilled = true; finished.fulfill() }
                return
            }
            frames += Double(pcm.frameLength)
            sampleRate = pcm.format.sampleRate
        }
        wait(for: [finished], timeout: 60)
        guard sampleRate > 0 else { throw XCTSkip("The system voice rendered no audio on this host") }
        return frames / sampleRate
    }
    #endif

    func testUnchosenVoiceIsTheBestInstalledForTheListenersLanguage() {
        let candidates = [
            SystemSpeechVoiceChoice.Candidate(identifier: "us-default", language: "en-US", qualityRank: 1, isLanguageDefault: true),
            SystemSpeechVoiceChoice.Candidate(identifier: "us-enhanced", language: "en-US", qualityRank: 2),
            SystemSpeechVoiceChoice.Candidate(identifier: "gb-premium", language: "en-GB", qualityRank: 3),
            SystemSpeechVoiceChoice.Candidate(identifier: "fr-premium", language: "fr-FR", qualityRank: 3)
        ]
        XCTAssertEqual(SystemSpeechVoiceChoice.preferredVoiceIdentifier(among: candidates, preferredLanguages: ["en-US"]), "us-enhanced")
        XCTAssertEqual(SystemSpeechVoiceChoice.preferredVoiceIdentifier(among: candidates, preferredLanguages: ["en-AU"]), "gb-premium", "same language, other region")
        XCTAssertEqual(SystemSpeechVoiceChoice.preferredVoiceIdentifier(among: candidates, preferredLanguages: ["de-DE", "fr-CA"]), "fr-premium")
        XCTAssertNil(SystemSpeechVoiceChoice.preferredVoiceIdentifier(among: candidates, preferredLanguages: ["ja-JP"]))
        let tie = [
            SystemSpeechVoiceChoice.Candidate(identifier: "a", language: "en-US", qualityRank: 1),
            SystemSpeechVoiceChoice.Candidate(identifier: "default", language: "en-US", qualityRank: 1, isLanguageDefault: true)
        ]
        XCTAssertEqual(SystemSpeechVoiceChoice.preferredVoiceIdentifier(among: tie, preferredLanguages: ["en_US"]), "default")
    }
}
