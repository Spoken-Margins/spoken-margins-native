import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest

/// Verifies session policy on real playback adapters. These checks do not
/// establish audible balance with Spotify or physical-device route behavior.
@MainActor
final class MixedPlaybackAudioSessionTests: XCTestCase {
    func testDuckingRequiresBothMixingAndExplicitOptIn() {
        XCTAssertEqual(PlaybackAudioSessionPolicy.options(mixes: false, lowersBackground: false), [])
        XCTAssertEqual(PlaybackAudioSessionPolicy.options(mixes: false, lowersBackground: true), [])
        XCTAssertEqual(PlaybackAudioSessionPolicy.options(mixes: true, lowersBackground: false), [.mixWithOthers])
        XCTAssertEqual(PlaybackAudioSessionPolicy.options(mixes: true, lowersBackground: true), [.mixWithOthers, .duckOthers])
    }

    func testPreparedPlaybackReleasesDuckingOnPauseAndRestoresItOnResume() throws {
        let url = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = PreparedAudioPlaybackClient()
        defer { try? client.stop() }
        try client.prepareAudioFile(targetId: "sample", fileURL: url)
        try exercisePolicy(client, targetId: "sample")
    }

    func testStreamPlaybackReleasesDuckingOnPauseAndRestoresItOnResume() throws {
        let url = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = AVPlayerStreamPlaybackClient()
        client.setRemoteCommandHandlingEnabled(false)
        defer { try? client.stop() }
        try exercisePolicy(client, targetId: url.absoluteString)
    }

    func testPreparedPlaybackCompletionRestoresBackgroundAudio() async throws {
        let url = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = PreparedAudioPlaybackClient()
        defer { try? client.stop() }
        try client.prepareAudioFile(targetId: "sample", fileURL: url)
        try client.setMixesWithOtherAudio(true)
        try client.setLowersBackgroundAudio(true)
        try client.play(targetId: "sample", fromMediaTimeMs: 2_800)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.duckOthers))
        for _ in 0..<40 {
            if client.isPlaybackComplete(targetId: "sample") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(client.isPlaybackComplete(targetId: "sample"))
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.duckOthers))
    }

    func testReleasingDuckingDoesNotChangeRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        defer { try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers]) }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [])
        try PlaybackAudioSessionPolicy.releaseDucking()
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
    }

    private func exercisePolicy(_ client: AudioPlaybackClient, targetId: String) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try client.setMixesWithOtherAudio(true)
        try client.play(targetId: targetId, fromMediaTimeMs: 0)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))

        try client.setLowersBackgroundAudio(true)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers))
        try client.setPlaybackVolume(0.35)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "Speech volume is independent of background attenuation")
        try client.pause()
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))

        // Toggling while paused must not start ducking or reactivate playback.
        try client.setLowersBackgroundAudio(false)
        try client.setLowersBackgroundAudio(true)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        // Recording temporarily uses an exclusive session; resuming restores both options.
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [])
        try client.play(targetId: targetId, fromMediaTimeMs: 0)
        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers))
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))

        try client.setLowersBackgroundAudio(false)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        try client.setLowersBackgroundAudio(true)
        try client.stop()
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
    }

    private func makeAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mix-policy-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 72_000))
        buffer.frameLength = 72_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.update(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
