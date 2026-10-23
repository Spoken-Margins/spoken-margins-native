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

    /// Real AVFoundation: renders the same passage at every speed the speed button offers, in the two voices
    /// `SpeechRateRule`'s table was measured with (Samantha and Eddy, macOS 26), and times it.
    ///
    /// The table inverts the average of those two voices' curves, so the average is held to the documented
    /// 10%. Each voice on its own is held to 20%: measured on macOS 26 (2026-10-10), Samantha is about 11%
    /// fast at 0.5× and 0.75× and Eddy about 17% slow at 0.5×, while their average stays within 4% at every
    /// speed. Before #183, 1.5× was heard at about 2.5× and 1.75× at about 3×.
    /// Rendering is deterministic, so a failure that starts with a macOS update means the voices changed: re-measure
    /// the table rather than hunting for a code regression.
    ///
    /// 0.5× is not held (#2469): on macOS 27 Samantha's 0.5× is heard at about 0.63×, and the owner's call is that
    /// "no one listens that slow. it is fine" (2026-10-23). The speeds listeners use, 0.75× and up, keep the claim.
    func testNarrationIsHeardAtTheChosenSpeed() throws {
        let measuredVoices = [
            "com.apple.voice.compact.en-US.Samantha",
            "com.apple.eloquence.en-US.Eddy"
        ].compactMap(AVSpeechSynthesisVoice.init(identifier:))
        guard measuredVoices.count == 2 else {
            throw XCTSkip("Samantha and Eddy, the voices the rate table was measured with, are not both installed on this host")
        }
        let passage = "The listener picks a speed, and narration should play at that speed whichever voice is speaking. This passage is long enough to time."
        func heardSeconds(_ voice: AVSpeechSynthesisVoice, multiplier: Double) throws -> Double {
            let client = SystemSpeechPlaybackClient(voiceIdentifier: voice.identifier, speechRate: 0.5)
            try client.setPlaybackRate(multiplier)
            let utterance = try client.makeNarrationUtterance(passage)
            XCTAssertEqual(utterance.voice?.identifier, voice.identifier, "narration speaks the chosen voice")
            return try renderedSeconds(utterance, describing: "\(voice.name) at \(multiplier)×")
        }
        // Heard speed divided by chosen speed, per voice: 1 means heard exactly at the chosen speed.
        var errors: [Double: [Double]] = [:]
        for voice in measuredVoices {
            let normal = try heardSeconds(voice, multiplier: 1)
            // 24 words at normal speed take 7 to 9 seconds in both voices; a ratio of near-silences would pass the rest.
            XCTAssertGreaterThan(normal, 4, "\(voice.name) speaks the whole passage at 1×")
            for multiplier in SpeechRateRule.supportedMultipliers where multiplier >= 0.75 && multiplier != 1 {
                let heard = normal / (try heardSeconds(voice, multiplier: multiplier))
                let ratio = heard / multiplier
                errors[multiplier, default: []].append(ratio)
                XCTAssertEqual(ratio, 1, accuracy: 0.20, "\(voice.name): \(multiplier)× heard at \(heard)×")
            }
        }
        for (multiplier, ratios) in errors.sorted(by: { $0.key < $1.key }) {
            let average = ratios.reduce(0, +) / Double(ratios.count)
            XCTAssertEqual(average, 1, accuracy: 0.10, "\(multiplier)× heard at \(average * multiplier)× on average across the measured voices")
        }
    }

    /// Fails, rather than skips, when a found voice renders nothing: narration that makes no sound is the bug.
    private func renderedSeconds(_ utterance: AVSpeechUtterance, describing what: String) throws -> Double {
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
        wait(for: [finished], timeout: 30)
        guard sampleRate > 0, frames > 0 else {
            struct RenderedNoAudio: Error, CustomStringConvertible { let description: String }
            throw RenderedNoAudio(description: "\(what) rendered no audio")
        }
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
