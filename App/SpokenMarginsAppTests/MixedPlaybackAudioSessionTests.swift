import AVFoundation
import SessionKit
import SessionKitAudio
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

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

    /// APA-02 (#1042): Supertonic narrates most articles, and its tests all inject a session activator, which
    /// also skips the release of ducking (`releaseBackgroundAudio`), so only a call counter covered it. Here the
    /// client runs on the real session: other audio is lowered while it plays, not while it is paused, again
    /// on resume, follows the setting while playing, and stops being lowered when the article ends.
    func testSupertonicLowersOtherAudioOnlyWhilePlayingOnTheRealSession() async throws {
        let template = try makeAudioFile(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let session = AVAudioSession.sharedInstance()
        defer { try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers]) }
        try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        let starts = StartCount()
        let client = SupertonicSpeechPlaybackClient(
            renderer: TemplateSupertonicRenderer(templateURL: template), voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioPlayerStarter: { player, rate in
                starts.add()
                player.volume = 0
                player.playImmediately(atRate: rate)
            },
            fallbackClient: NoopAudioPlaybackClient()
        )
        defer { try? client.stop() }
        try client.setMixesWithOtherAudio(true)
        try client.setLowersBackgroundAudio(true)
        _ = try client.prepareSpeechText("One sentence of narration is enough for this chunk.")
        try client.play(targetId: "mix", from: 0)
        for _ in 0..<250 where starts.value < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(starts.value, 1, "the rendered chunk started")
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "playing lowers other audio")

        try client.pause()
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "paused, other audio is no longer lowered")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers), "and still mixes, so the other app isn't interrupted")
        XCTAssertEqual(session.category, .playback)

        try client.play(targetId: "mix", from: client.currentCharOffset() ?? 0)
        for _ in 0..<150 where !session.categoryOptions.contains(.duckOthers) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "resuming lowers other audio again")

        try client.setLowersBackgroundAudio(false)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "turning the setting off while playing takes effect at once")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        try client.setLowersBackgroundAudio(true)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "and turning it on again does too")

        for _ in 0..<300 where client.playbackTransportState(targetId: "mix") != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.playbackTransportState(targetId: "mix"), .stopped, "the article played to its end")
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "the end of the article stops lowering other audio")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    }

    /// APA-02 (#1042), the iOS voice half: the iOS voice reads articles when Supertonic isn't chosen or falls back,
    /// and it wasn't among the adapters here. On the real session, speaking lowers other audio; pausing, stopping
    /// and reaching the end stop lowering it, while mixing stays on so the other app isn't interrupted. The speech
    /// itself runs at volume 0.
    func testIOSVoiceLowersOtherAudioOnlyWhileSpeakingOnTheRealSession() async throws {
        let session = AVAudioSession.sharedInstance()
        defer { try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers]) }
        try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        let client = SystemSpeechPlaybackClient(voiceIdentifier: nil, speechRate: 0.5)
        defer { try? client.stop() }
        try client.setPlaybackVolume(0)
        try client.setMixesWithOtherAudio(true)
        try client.setLowersBackgroundAudio(true)
        _ = try client.prepareSpeechText(String(repeating: "The iOS voice reads this article long enough to pause it. ", count: 12))

        try client.play(targetId: "long", from: 0)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "speaking lowers other audio")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))

        try client.pause()
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "paused, other audio is no longer lowered")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers), "and still mixes, so the other app isn't interrupted")
        XCTAssertEqual(session.category, .playback)

        try client.play(targetId: "long", from: client.currentCharOffset() ?? 0)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "resuming lowers other audio again")
        try client.setLowersBackgroundAudio(false)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "turning the setting off while speaking takes effect at once")
        try client.setLowersBackgroundAudio(true)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "and turning it on again does too")

        try client.stop()
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "stopped, other audio is no longer lowered")

        _ = try client.prepareSpeechText("Short.")
        try client.play(targetId: "short", from: 0)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "precondition: the short article lowers other audio")
        let deadline = ContinuousClock.now + .seconds(20)
        while !client.isPlaybackComplete(targetId: "short"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(client.isPlaybackComplete(targetId: "short"), "the iOS voice read the short article to its end")
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "the end of the article stops lowering other audio")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    }

    func testReleasingDuckingDoesNotChangeRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        defer { try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers]) }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [])
        try PlaybackAudioSessionPolicy.releaseDucking()
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))

        // APA-07 (#1042): a release only ever acts on a session that lowers other audio, so the
        // recording session above returns early whatever its category. A Margin recording session
        // that lowers other audio is the case the category check protects: a stray release must
        // leave it recording, with its options as they were.
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "precondition: the recording session lowers other audio")
        try PlaybackAudioSessionPolicy.releaseDucking()
        XCTAssertEqual(session.category, .playAndRecord, "a release must not turn the recording session into playback")
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "a release leaves a recording session's options alone")
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

    private func makeAudioFile(seconds: Double = 3) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mix-policy-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let frames = AVAudioFrameCount(24_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.update(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private final class StartCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// Hands back a copy of one audio file for every chunk, as the Supertonic renderer hands back its own files.
private actor TemplateSupertonicRenderer: SupertonicRendering {
    let templateURL: URL

    init(templateURL: URL) { self.templateURL = templateURL }

    func render(
        text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        let url = FileManager.default.temporaryDirectory.appending(path: "mix-render-\(UUID().uuidString).caf")
        try FileManager.default.copyItem(at: templateURL, to: url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url,
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
            renderDuration: 0.01,
            sessionLoadCount: 1,
            engine: SupertonicNarrationResult.supertonicEngine
        )
    }

    func discardGeneratedAudio(at url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }
}
