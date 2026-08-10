import AVFoundation
import SessionKit
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

@MainActor
final class SupertonicSpeechTests: XCTestCase {
    func testSelectableCatalogExposesOnlyJamesLilyAndSystem() {
        XCTAssertEqual(AppTTSVoiceSelection.allCases, [.james, .lily, .system])
        XCTAssertEqual(AppTTSVoiceSelection.james.rawValue, "supertonic:M2")
        XCTAssertEqual(AppTTSVoiceSelection.james.supertonicVoice, .m2)
        XCTAssertEqual(AppTTSVoiceSelection.lily.rawValue, "supertonic:F2")
        XCTAssertEqual(AppTTSVoiceSelection.lily.supertonicVoice, .f2)
        XCTAssertNil(AppTTSVoiceSelection.system.supertonicVoice)
    }

    func testChunkerPrefersSentenceThenCommaThenWhitespaceAndCapsLength() {
        let sentence = String(repeating: "opening words ", count: 8) + "finished. More text follows."
        let sentenceSlice = RenderedSpeechChunker.selectChunkPrefix(sentence, maxCharacters: 150)
        XCTAssertEqual(sentenceSlice.boundary, .sentence)
        XCTAssertTrue(sentenceSlice.text.hasSuffix("."))

        let comma = String(repeating: "opening words ", count: 8) + "pause, more text follows"
        let commaSlice = RenderedSpeechChunker.selectChunkPrefix(comma, maxCharacters: 150)
        XCTAssertEqual(commaSlice.boundary, .comma)
        XCTAssertTrue(commaSlice.text.hasSuffix(","))

        let whitespace = String(repeating: "abcdefghij ", count: 30)
        let whitespaceSlice = RenderedSpeechChunker.sourceSlice(from: whitespace, startOffset: 0)
        XCTAssertEqual(whitespaceSlice.boundary, .whitespace)
        XCTAssertLessThanOrEqual(whitespaceSlice.sourceLength, 240)
        XCTAssertFalse(whitespaceSlice.text.hasSuffix(" "))
    }

    func testChunkerMaintainsSourceOffsetsAcrossEmojiAndWhitespace() {
        let prefix = "Intro 😀 sentence. "
        let source = prefix + String(repeating: "Long body words ", count: 30)
        let slice = RenderedSpeechChunker.sourceSlice(from: source, startOffset: prefix.count)
        XCTAssertFalse(slice.text.isEmpty)
        XCTAssertLessThanOrEqual(prefix.count + slice.sourceLength, source.count)
        let start = source.index(source.startIndex, offsetBy: prefix.count)
        let end = source.index(start, offsetBy: slice.sourceLength)
        XCTAssertTrue(String(source[start..<end]).contains(slice.text.prefix(8)))
    }

    func testRenderFailureFallsBackAtLastConfirmedSourceOffset() async throws {
        let fallback = RecordingFallbackAudioClient()
        let callback = expectation(description: "fallback callback")
        let client = SupertonicSpeechPlaybackClient(
            renderer: FailingSupertonicRenderer(),
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: fallback
        ) { reason, offset in
            XCTAssertEqual(reason, "supertonic_render_failed:Failure")
            XCTAssertEqual(offset, 17)
            callback.fulfill()
        }
        let source = "Start here, then continue through the rest of this sentence."
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "item", from: 17)

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(fallback.preparedText, source)
        XCTAssertEqual(fallback.playedOffsets, [17])
        XCTAssertEqual(client.currentCharOffset(), 17)
    }

    func testMalformedRenderedAudioFallsBackWithoutAdvancingOffset() async throws {
        let malformedURL = FileManager.default.temporaryDirectory
            .appending(path: "malformed-\(UUID().uuidString).wav")
        try Data("not a wav".utf8).write(to: malformedURL)
        defer { try? FileManager.default.removeItem(at: malformedURL) }
        let fallback = RecordingFallbackAudioClient()
        let callback = expectation(description: "malformed audio fallback")
        let client = SupertonicSpeechPlaybackClient(
            renderer: FixedAudioSupertonicRenderer(audioURL: malformedURL),
            voice: .f2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: fallback
        ) { reason, offset in
            XCTAssertEqual(reason, "supertonic_playback_failed")
            XCTAssertEqual(offset, 9)
            callback.fulfill()
        }
        _ = try client.prepareSpeechText("Continue this sentence after the confirmed offset.")
        try client.play(targetId: "malformed", from: 9)

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(fallback.playedOffsets, [9])
    }

    func testPlaybackPrefetchesExactlyOneFollowingChunk() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: RecordingFallbackAudioClient()
        )
        let source = (1...8).map { index in
            "Sentence \(index) contains enough ordinary words to form a useful spoken chunk."
        }.joined(separator: " ")
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "prefetch")

        let renderCount = await waitForRenderCount(renderer, minimum: 2)
        XCTAssertEqual(renderCount, 2)
        XCTAssertEqual(client.playbackStartStatus(targetId: "prefetch"), .confirmed)
        try client.stop()
    }

    func testGenerationTokenDiscardsStaleRenderAfterReplay() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, firstRenderDelay: .milliseconds(120))
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: RecordingFallbackAudioClient()
        )
        let source = String(repeating: "This replay text has stable source offsets. ", count: 10)
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "generation", from: 0)
        try client.play(targetId: "generation", from: 12)

        let discarded = await waitForDiscardCount(renderer, minimum: 1)
        XCTAssertGreaterThanOrEqual(discarded, 1)
        try client.stop()
    }

    func testBackgroundingDuringInitialRenderStartsSystemFallbackImmediately() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            firstRenderDelay: .milliseconds(300)
        )
        let fallback = RecordingFallbackAudioClient()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            observesPlayerLifecycle: false,
            fallbackClient: fallback
        )
        let source = "Playback should become audible before the app is suspended during initial rendering."
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "background-start", from: 11)
        XCTAssertEqual(client.playbackStartStatus(targetId: "background-start"), .pending)

        XCTAssertTrue(client.ensurePlaybackStartsBeforeBackgrounding())

        XCTAssertEqual(fallback.preparedText, source)
        XCTAssertEqual(fallback.playedOffsets, [11])
        XCTAssertEqual(client.playbackStartStatus(targetId: "background-start"), .confirmed)
        XCTAssertEqual(client.playbackTransportState(targetId: "background-start"), .playing)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fallback.playedOffsets, [11], "A stale render replaced the background fallback")
        try client.stop()
    }

    func testRateChangeUsesTransportWithoutChangingSynthesisOrRestartingRender() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText("A short rendered sentence remains reusable at every transport speed.")
        try client.play(targetId: "rate")
        let initialRenderCount = await waitForRenderCount(renderer, minimum: 1)
        XCTAssertEqual(initialRenderCount, 1)

        try client.setPlaybackRate(1.7)
        try? await Task.sleep(for: .milliseconds(100))

        let renderCount = await renderer.renderCount
        let requestedSpeeds = await renderer.requestedSpeeds
        XCTAssertEqual(renderCount, 1)
        XCTAssertEqual(requestedSpeeds, [1.0])
        XCTAssertEqual(client.currentPlaybackPosition()?.playbackRate ?? 0, 1.7, accuracy: 0.001)
        try client.stop()
    }

    func testPauseDuringInitialRenderPreventsAutoplayAndResumeReusesResult() async throws {
        let template = try makeTestWAV(duration: 1)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            firstRenderDelay: .milliseconds(150)
        )
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText("Pause must win even while the first audio chunk is still rendering.")
        try client.play(targetId: "pending-pause")
        try client.pause()
        let initialRenderCount = await waitForRenderCount(renderer, minimum: 1)
        XCTAssertEqual(initialRenderCount, 1)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(client.playbackTransportState(targetId: "pending-pause"), .paused)
        XCTAssertEqual(client.currentRecoveryCharOffset(), 0)

        try client.play(targetId: "pending-pause", from: 0)
        for _ in 0..<50 where client.playbackStartStatus(targetId: "pending-pause") != .confirmed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.playbackStartStatus(targetId: "pending-pause"), .confirmed)
        let renderCount = await renderer.renderCount
        XCTAssertEqual(renderCount, 1)
        try client.stop()
    }

    func testMediaServicesResetRetainsRenderedChunkForExplicitResume() async throws {
        let template = try makeTestWAV(duration: 5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let notificationCenter = NotificationCenter()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionNotificationCenter: notificationCenter,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText("A media services reset should preserve this rendered audio chunk.")
        try client.play(targetId: "media-services-reset")
        for _ in 0..<50 where !client.debugActiveAudioState().hasURL {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.playbackStartStatus(targetId: "media-services-reset"), .confirmed)
        let preResetRenderCount = await renderer.renderCount
        XCTAssertEqual(preResetRenderCount, 1, "Unexpected render before media-services reset")
        let preResetAudio = client.debugActiveAudioState()
        XCTAssertTrue(preResetAudio.hasURL)
        XCTAssertGreaterThan(preResetAudio.duration, 0)
        XCTAssertEqual(preResetAudio.targetId, "media-services-reset")
        XCTAssertEqual(preResetAudio.startOffset, 0)

        notificationCenter.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(client.playbackTransportState(targetId: "media-services-reset"), .paused)
        let postResetRenderCount = await renderer.renderCount
        XCTAssertEqual(postResetRenderCount, 1, "Media-services reset unexpectedly re-rendered audio")
        XCTAssertEqual(client.currentRecoveryCharOffset(), 0)
        XCTAssertEqual(client.debugRenderedCacheOffsets(), [0])

        try client.play(targetId: "media-services-reset", from: client.currentRecoveryCharOffset() ?? 0)
        for _ in 0..<50 where client.playbackStartStatus(targetId: "media-services-reset") != .confirmed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.playbackStartStatus(targetId: "media-services-reset"), .confirmed)
        let renderCount = await renderer.renderCount
        XCTAssertEqual(renderCount, 1)
        try client.stop()
    }

    func testRenderedSpeechDiskCacheReusesAudioAcrossPlaybackClients() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rendered-speech-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "This rendered sentence should survive stopping playback and constructing a new client."

        let firstRenderer = CountingAudioSupertonicRenderer(templateURL: template)
        let firstCache = try RenderedSpeechDiskCache(directory: root, limitBytes: 10 * 1024 * 1024)
        let firstClient = SupertonicSpeechPlaybackClient(
            renderer: firstRenderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            diskCache: firstCache,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try firstClient.prepareSpeechText(source)
        try firstClient.play(targetId: "first")
        let firstRenderCount = await waitForRenderCount(firstRenderer, minimum: 1)
        XCTAssertEqual(firstRenderCount, 1)
        try firstClient.stop()
        XCTAssertGreaterThan(firstCache.sizeBytes, 0)

        let secondRenderer = CountingAudioSupertonicRenderer(templateURL: template)
        let secondCache = try RenderedSpeechDiskCache(directory: root, limitBytes: 10 * 1024 * 1024)
        let secondClient = SupertonicSpeechPlaybackClient(
            renderer: secondRenderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            diskCache: secondCache,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try secondClient.prepareSpeechText(source)
        try secondClient.play(targetId: "second")
        for _ in 0..<50 where secondClient.playbackStartStatus(targetId: "second") != .confirmed {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let secondRenderCount = await secondRenderer.renderCount
        XCTAssertEqual(secondRenderCount, 0)
        XCTAssertEqual(secondClient.playbackStartStatus(targetId: "second"), .confirmed)
        try secondClient.stop()
    }

    func testBundledRendererSynthesizesJamesAndLilyAndReusesSessions() async throws {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw XCTSkip("Hosted app resources unavailable")
        }
        let root = resourceURL.appending(path: "Supertonic", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Supertonic assets are not present in this test host")
        }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let renderer = try SupertonicNarrationRenderer(
            assets: SupertonicAssetLocation(rootURL: root),
            outputDirectory: output
        )

        let james = try await renderer.render(text: "James reads this short test.", voice: .m2)
        let lily = try await renderer.render(text: "Lily reads this short test.", voice: .f2)

        XCTAssertEqual(james.sampleRate, 44_100)
        XCTAssertEqual(lily.sampleRate, 44_100)
        XCTAssertGreaterThan(james.duration, 0)
        XCTAssertGreaterThan(lily.duration, 0)
        XCTAssertGreaterThan(try audioPeak(at: james.audioURL), 0.000_001)
        XCTAssertGreaterThan(try audioPeak(at: lily.audioURL), 0.000_001)
        XCTAssertEqual(james.sessionLoadCount, 1)
        XCTAssertEqual(lily.sessionLoadCount, 1)
        let diagnostics = await renderer.diagnostics()
        XCTAssertEqual(diagnostics.sessionLoadCount, 1)
        await renderer.unload()
    }

    private func audioPeak(at url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ))
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        return peak
    }

    private func makeTestWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-test-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frameCount = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = sin(Float(frame) * 2 * .pi * 440 / 44_100) * 0.1
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func waitForRenderCount(
        _ renderer: CountingAudioSupertonicRenderer,
        minimum: Int
    ) async -> Int {
        for _ in 0..<100 {
            let count = await renderer.renderCount
            if count >= minimum { return count }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await renderer.renderCount
    }

    private func waitForDiscardCount(
        _ renderer: CountingAudioSupertonicRenderer,
        minimum: Int
    ) async -> Int {
        for _ in 0..<100 {
            let count = await renderer.discardCount
            if count >= minimum { return count }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await renderer.discardCount
    }
}

private struct Failure: Error {}

private struct FailingSupertonicRenderer: SupertonicRendering {
    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        throw Failure()
    }

    func discardGeneratedAudio(at url: URL) async {}
}

private struct FixedAudioSupertonicRenderer: SupertonicRendering {
    let audioURL: URL

    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        SupertonicNarrationResult(
            audioURL: audioURL,
            duration: 1,
            sampleRate: 44_100,
            renderDuration: 0.01,
            sessionLoadCount: 1
        )
    }

    func discardGeneratedAudio(at url: URL) async {}
}

private actor CountingAudioSupertonicRenderer: SupertonicRendering {
    let templateURL: URL
    let firstRenderDelay: Duration?
    private(set) var renderCount = 0
    private(set) var discardCount = 0
    private(set) var requestedSpeeds: [Float] = []

    init(templateURL: URL, firstRenderDelay: Duration? = nil) {
        self.templateURL = templateURL
        self.firstRenderDelay = firstRenderDelay
    }

    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        renderCount += 1
        requestedSpeeds.append(speed)
        if renderCount == 1, let firstRenderDelay {
            try await Task.sleep(for: firstRenderDelay)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "counting-render-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url,
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
            renderDuration: 0.01,
            sessionLoadCount: 1
        )
    }

    func discardGeneratedAudio(at url: URL) async {
        discardCount += 1
        try? FileManager.default.removeItem(at: url)
    }
}

private final class RecordingFallbackAudioClient: AudioPlaybackClient, @unchecked Sendable {
    var preparedText = ""
    var playedOffsets: [Int] = []
    var offset = 0

    func prepareSpeechText(_ text: String) throws -> String {
        preparedText = text
        return text
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        offset = charOffset
        playedOffsets.append(charOffset)
    }

    func currentCharOffset() -> Int? { offset }
    func pause() throws {}
}
