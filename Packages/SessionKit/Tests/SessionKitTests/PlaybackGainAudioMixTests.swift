#if canImport(AVFoundation) && canImport(MediaToolbox) && !os(watchOS)
import XCTest
@testable import SessionKitAudio

final class PlaybackGainAudioMixTests: XCTestCase {
    func testGainRangePreservesNormalAtUnityAndBoundsBoost() {
        XCTAssertEqual(PlaybackGainAudioMix.clampedGain(0.5), 1)
        XCTAssertEqual(PlaybackGainAudioMix.clampedGain(1), 1)
        XCTAssertEqual(PlaybackGainAudioMix.clampedGain(1.5), 1.5)
        XCTAssertEqual(PlaybackGainAudioMix.clampedGain(3), 2)
    }

    func testBoostMultipliesDecodedSpeechAndLimitsClipping() {
        XCTAssertEqual(PlaybackGainAudioMix.applyingGain(0.4, gain: 1), 0.4, accuracy: 0.000_1)
        XCTAssertEqual(PlaybackGainAudioMix.applyingGain(0.4, gain: 1.5), 0.6, accuracy: 0.000_1)
        XCTAssertEqual(PlaybackGainAudioMix.applyingGain(0.8, gain: 2), 1, accuracy: 0.000_1)
        XCTAssertEqual(PlaybackGainAudioMix.applyingGain(-0.8, gain: 2), -1, accuracy: 0.000_1)
    }
}
#endif
