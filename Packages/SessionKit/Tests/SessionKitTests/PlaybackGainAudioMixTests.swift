#if canImport(AVFoundation) && canImport(MediaToolbox) && !os(watchOS)
import XCTest
import AVFoundation
@testable import SessionKitAudio

final class PlaybackGainAudioMixTests: XCTestCase {
    @MainActor
    func testConfiguredPlayerItemInstallsGainMixForLocalRenderedAudio() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-gain-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        try file.write(from: buffer)

        let configured = PlaybackGainAudioMix.configuredPlayerItem(url: url, gain: 1.5)

        XCTAssertNotNil(configured.gainMix)
        XCTAssertNotNil(configured.item.audioMix)
    }

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
