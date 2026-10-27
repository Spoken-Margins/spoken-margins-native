import Foundation
import SessionKit

/// What the renderer needs from Gradium's `Phonon` (module `PhononTTS`). The app adapts the real one
/// (`PhononTTSEngine`); host tests pass a stand-in, since the Neural Engine runtime ships only in the app.
public protocol PhononSynthesizing: AnyObject, Sendable {
    /// The voice `synthesize` reads with.
    var voice: String { get }
    /// Conditions the model on another voice, up to about 0.6 s on a phone.
    func setVoice(_ name: String) async throws
    /// All of `text`'s samples, mono Float32 at `PhononVoice.sampleRate`. Cancelling the task stops generation.
    func synthesize(_ text: String) async throws -> [Float]
}

/// Loads Phonon from an installed bundle; the app's is `PhononTTSEngine.load`.
public typealias PhononEngineLoader = @Sendable (PhononModelLocation) async throws -> any PhononSynthesizing

/// The downloadable Phonon voice (#2704) through the narration-renderer seam Kitten uses: one paragraph in, one WAV
/// file out, never on the main thread. The model is loaded on first use and kept until `unload()`. Renders run one
/// at a time in the order asked. Phonon's LM runs on the Neural Engine and its codec on the CPU, so the CPU share is
/// paced by the shared `OnDeviceVoiceGovernor` in the background, as Kitten's and Supertonic's are (#1679).
public actor PhononNarrationRenderer {
    public static let engine = PhononVoice.engine
    public static let sampleRate = PhononVoice.sampleRate

    private let location: PhononModelLocation
    private let voiceName: String
    private let outputDirectory: URL
    private let load: PhononEngineLoader
    public nonisolated let governor: OnDeviceVoiceGovernor
    private var phonon: (any PhononSynthesizing)?
    private var sessionLoadCount = 0
    private var generatedAudioURLs: Set<URL> = []
    /// When the next inference may start, from the last one's cost (#1679).
    private var nextInferenceNotBefore: TimeInterval?
    /// The render in progress, so the next waits for it: an actor alone would interleave two renders at each await.
    private var tail: Task<Void, Never>?

    /// `location` is the installed bundle (`VoiceModelInstaller`'s version folder for `phonon-31m-en`).
    public init(
        location: PhononModelLocation,
        voiceName: String = PhononVoice.defaultVoiceName,
        outputDirectory: URL,
        governor: OnDeviceVoiceGovernor,
        load: @escaping PhononEngineLoader,
        fileManager: FileManager = .default
    ) throws {
        guard PhononVoice.isKnownVoice(voiceName) else { throw PhononModelError.unknownVoice(voiceName) }
        try location.validate(voice: voiceName, fileManager: fileManager)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        self.location = location
        self.voiceName = voiceName
        self.outputDirectory = outputDirectory
        self.governor = governor
        self.load = load
    }

    /// The identity this renderer's audio is saved under, from the catalog entry the bundle was installed from.
    public nonisolated func signature(entry: VoiceModelEntry) -> TTSRenderSignature? {
        PhononRenderSignature.make(entry: entry, voice: voiceName)
    }

    /// Live narration: paced only while the app is in the background.
    public func render(text: String) async throws -> SupertonicNarrationResult {
        try await render(text: text, pacing: .whenAppBackgrounded)
    }

    public func render(text: String, pacing: OnDeviceRenderPacing) async throws -> SupertonicNarrationResult {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw PhononModelError.emptyText }
        try Task.checkCancellation()
        // Wait for the render ahead, and leave a turn the next one waits on until this one is done.
        let previous = tail
        let gate = AsyncTurn()
        tail = Task { [previous] in
            await previous?.value
            await gate.wait()
        }
        await previous?.value
        defer { gate.open() }
        return try await renderNow(spoken, pacing: pacing)
    }

    private func renderNow(_ spoken: String, pacing: OnDeviceRenderPacing) async throws -> SupertonicNarrationResult {
        if let notBefore = nextInferenceNotBefore {
            try await waitOffActor(notBefore: notBefore, pacing: pacing)
            nextInferenceNotBefore = nil
        }
        try Task.checkCancellation()
        let startedAt = Date()
        // Loading (and, on a first launch after an install, compiling) is paid once and isn't counted as inference.
        let phonon = try await loadIfNeeded()
        let wallStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = OnDeviceVoiceGovernor.processCPUTime()
        let samples = try await phonon.synthesize(spoken)
        try Task.checkCancellation()
        let cpu = OnDeviceVoiceGovernor.processCPUTime() - cpuStart
        let cost = OnDeviceVoiceGovernor.InferenceCost(wall: max(0, ProcessInfo.processInfo.systemUptime - wallStart), cpu: cpu > 0 ? cpu : nil)
        nextInferenceNotBefore = governor.nextInference(after: cost, pacing: pacing)

        try PhononAudioCheck.validate(samples)
        let rate = Self.sampleRate
        let kept = SpeechSilenceTrim.speechRange(in: samples, sampleRate: rate).map { Array(samples[$0]) } ?? samples
        let trimmedSilence = TimeInterval(samples.count - kept.count) / TimeInterval(rate)
        let audioURL = outputDirectory.appending(path: "phonon-\(UUID().uuidString).wav")
        try writeWavFile(audioURL.path, kept, rate)
        generatedAudioURLs.insert(audioURL)
        return SupertonicNarrationResult(
            audioURL: audioURL,
            duration: TimeInterval(kept.count) / TimeInterval(rate),
            sampleRate: rate,
            renderDuration: Date().timeIntervalSince(startedAt),
            sessionLoadCount: sessionLoadCount,
            engine: Self.engine,
            trimmedSilence: trimmedSilence
        )
    }

    /// The governor's wait sleeps its thread, so it runs on a background queue, not on the actor.
    private func waitOffActor(notBefore: TimeInterval, pacing: OnDeviceRenderPacing) async throws {
        let governor = governor
        let cancelled = CancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try governor.waitForNextInference(notBefore: notBefore, pacing: pacing) {
                            guard !cancelled.isCancelled else { throw CancellationError() }
                            return true
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    private func loadIfNeeded() async throws -> any PhononSynthesizing {
        if let phonon { return phonon }
        let loaded = try await load(location)
        if loaded.voice != voiceName { try await loaded.setVoice(voiceName) }
        phonon = loaded
        sessionLoadCount += 1
        return loaded
    }

    /// Drops the model, and by default the audio this renderer wrote.
    public func unload(removingGeneratedAudio: Bool = true) {
        phonon = nil
        if removingGeneratedAudio {
            for url in generatedAudioURLs { try? FileManager.default.removeItem(at: url) }
            generatedAudioURLs.removeAll()
        }
    }

    /// Deletes `url` only if this renderer wrote it (callers also pass files other renderers own).
    public func discardGeneratedAudio(at url: URL) {
        if generatedAudioURLs.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
    }

    public func diagnostics() -> (sessionLoadCount: Int, generatedFileCount: Int) {
        (sessionLoadCount, generatedAudioURLs.count)
    }
}

/// The output checks Kitten's renderer makes, for Phonon's samples: finite, and not silent.
public enum PhononAudioCheck {
    public static func validate(_ samples: [Float]) throws {
        guard !samples.isEmpty else { throw PhononModelError.emptyAudio }
        guard samples.allSatisfy(\.isFinite) else { throw PhononModelError.unsafeAudio("non_finite_samples") }
        guard samples.lazy.map({ abs($0) }).max() ?? 0 > 0.000_001 else { throw PhononModelError.unsafeAudio("silent_output") }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// A one-shot gate a waiting task can await until the render ahead of it opens it.
private final class AsyncTurn: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}
