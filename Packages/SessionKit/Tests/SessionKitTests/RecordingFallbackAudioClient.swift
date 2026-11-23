import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio

/// The iOS voice stand-in the client tests hand to `SupertonicSpeechPlaybackClient` (#4691). A copy of the
/// app test target's, which the tests that stay app-hosted still use.
final class RecordingFallbackAudioClient: AudioPlaybackClient, SpokenProgressReporting, @unchecked Sendable {
    var preparedText = ""
    var playedOffsets: [Int] = []
    var playbackRates: [Double] = []
    var mixingStates: [Bool] = []
    var backgroundAudioStates: [Bool] = []
    var playbackVolumes: [Float] = []
    var pauseCount = 0
    var offset = 0
    /// How far the place moves each time it is read, as a speaking voice's would.
    var advancesPerRead = 0
    var completedTargetId: String?
    /// Words started, as the iOS voice counts them; nil for a voice that can't count them.
    var spokenWords: Int?
    var wordsPerRead = 0
    /// How many times the place was asked for: the stall monitor asks once per sample (#4313).
    private(set) var progressReads = 0
    /// Set to make the iOS voice refuse to start, as a session that can't be activated would.
    var playError: Error?
    /// What the iOS voice says about having begun: `.pending` is speech queued that never started.
    var startStatus: PlaybackStartStatus = .confirmed
    var stopCount = 0
    /// Plays ("play:<offset>"), pauses and stops in the order they happened, with anything else the test
    /// records into it (an audio session activation), so a test can check the order of a recovery (APA-05).
    var events: [String] { eventLock.withLock { recordedEvents } }
    private let eventLock = NSLock()
    private var recordedEvents: [String] = []
    func record(_ event: String) { eventLock.withLock { recordedEvents.append(event) } }

    func prepareSpeechText(_ text: String) throws -> String {
        preparedText = text
        return text
    }

    func isPlaybackComplete(targetId: String) -> Bool { completedTargetId == targetId }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatus }

    func stop() throws { stopCount += 1; record("stop") }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        if let playError { throw playError }
        offset = charOffset
        playedOffsets.append(charOffset)
        record("play:\(charOffset)")
    }

    func currentCharOffset() -> Int? {
        defer { offset += advancesPerRead }
        return offset
    }

    func spokenProgress() -> Int? {
        progressReads += 1
        defer { spokenWords = spokenWords.map { $0 + wordsPerRead } }
        return spokenWords
    }

    func setPlaybackRate(_ rate: Double) throws {
        playbackRates.append(rate)
    }

    func setMixesWithOtherAudio(_ enabled: Bool) throws {
        mixingStates.append(enabled)
    }

    func setLowersBackgroundAudio(_ enabled: Bool) throws {
        backgroundAudioStates.append(enabled)
    }

    func setPlaybackVolume(_ volume: Float) throws {
        playbackVolumes.append(volume)
    }

    func pause() throws {
        pauseCount += 1
        record("pause")
    }
}

/// A narration player whose clock the test sets: SessionEngine reads the Margin's moment from it.
private final class NarrationClockAudioClient: AudioPlaybackClient {
    var mediaTimeMs: Int?
    private let durationMs: Int
    private var target: String?

    init(durationMs: Int) { self.durationMs = durationMs }

    func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    func play(targetId: String) throws { target = targetId; mediaTimeMs = mediaTimeMs ?? 0 }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws { target = targetId; self.mediaTimeMs = mediaTimeMs }
    func pause() throws {}
    func stop() throws { target = nil }
    func currentCharOffset() -> Int? { nil }
    func currentRecoveryCharOffset() -> Int? { nil }
    func currentMediaTimeMs() -> Int? { mediaTimeMs }
    func currentPlaybackDurationMs() -> Int? { durationMs }
    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map { PlaybackPosition(targetId: target, mediaTimeMs: $0, durationMs: durationMs, playbackRate: 1, anchorConfidence: .mediaTime) }
    }
    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { .confirmed }
    func isAwaitingRenderedAudio(targetId: String) -> Bool { false }
    func playbackTransportState(targetId: String) -> PlaybackTransportState? { nil }
    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {}
}

/// A renderer whose first render spends `loadTime` loading its model and says so through `isLoadingModel` (#2856).
private final class LoadingModelRenderer: SupertonicRendering, @unchecked Sendable {
    private let inner: CountingAudioSupertonicRenderer
    private let loadTime: Duration
    private let lock = NSLock()
    private var loading = false

    init(inner: CountingAudioSupertonicRenderer, loadTime: Duration) {
        self.inner = inner
        self.loadTime = loadTime
    }

    var isLoadingModel: Bool { lock.withLock { loading } }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        lock.withLock { loading = true }
        defer { lock.withLock { loading = false } }
        try await Task.sleep(for: loadTime)
        return try await inner.render(text: text, voice: voice, language: language, speed: speed, synthesisSteps: synthesisSteps)
    }

    func discardGeneratedAudio(at url: URL) async { await inner.discardGeneratedAudio(at: url) }
}


/// A renderer that is loading its model from the moment it exists and holds its render until `finishLoading()` (#3437).
/// It counts how often the client asked whether it was loading, so a test can wait for the wait limit to pass.
private final class HeldLoadingModelRenderer: SupertonicRendering, @unchecked Sendable {
    struct NoLoadingChecks: Error {}

    private let inner: CountingAudioSupertonicRenderer
    private let gate: AsyncStream<Void>
    private let openGate: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var checks = 0

    init(inner: CountingAudioSupertonicRenderer) {
        self.inner = inner
        let pair = AsyncStream<Void>.makeStream()
        gate = pair.stream
        openGate = pair.continuation
    }

    /// True for as long as the render is held and after it, so the client never sees a gap between load and result.
    var isLoadingModel: Bool { lock.withLock { checks += 1; return true } }

    func finishLoading() { openGate.finish() }

    func waitForLoadingChecks(_ count: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while lock.withLock({ checks }) < count {
            guard ContinuousClock.now < deadline else { throw NoLoadingChecks() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        for await _ in gate {}
        try Task.checkCancellation()
        return try await inner.render(text: text, voice: voice, language: language, speed: speed, synthesisSteps: synthesisSteps)
    }

    func discardGeneratedAudio(at url: URL) async { await inner.discardGeneratedAudio(at: url) }
}
