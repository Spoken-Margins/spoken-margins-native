import Foundation
import OnnxRuntimeBindings
import SessionKit

public enum SupertonicVoiceID: String, CaseIterable, Codable, Sendable {
    case f1 = "F1"
    case f2 = "F2"
    case f3 = "F3"
    case f4 = "F4"
    case f5 = "F5"
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
    case m4 = "M4"
    case m5 = "M5"
}

public struct SupertonicAssetLocation: Equatable, Sendable {
    public let rootURL: URL
    public let onnxDirectoryURL: URL
    public let voiceStylesDirectoryURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.onnxDirectoryURL = rootURL.appending(path: "onnx", directoryHint: .isDirectory)
        self.voiceStylesDirectoryURL = rootURL.appending(path: "voice_styles", directoryHint: .isDirectory)
    }

    public func voiceStyleURL(for voice: SupertonicVoiceID) -> URL {
        voiceStylesDirectoryURL.appending(path: "\(voice.rawValue).json")
    }

    public func validate(fileManager: FileManager = .default) throws {
        let requiredModelFiles = [
            "duration_predictor.onnx",
            "text_encoder.onnx",
            "vector_estimator.onnx",
            "vocoder.onnx",
            "tts.json",
            "unicode_indexer.json"
        ]
        for file in requiredModelFiles {
            let url = onnxDirectoryURL.appending(path: file)
            guard fileManager.fileExists(atPath: url.path) else {
                throw SupertonicNarrationError.missingAsset(file)
            }
        }
        for voice in SupertonicVoiceID.allCases {
            let url = voiceStyleURL(for: voice)
            guard fileManager.fileExists(atPath: url.path) else {
                throw SupertonicNarrationError.missingAsset("voice_styles/\(voice.rawValue).json")
            }
        }
    }
}

public struct SupertonicNarrationResult: Equatable, Sendable {
    public let audioURL: URL
    /// Length of the audio file: the speech and its pads, with the model's extra silence cut (#586).
    public let duration: TimeInterval
    public let sampleRate: Int
    public let renderDuration: TimeInterval
    public let sessionLoadCount: Int
    /// Which engine made the audio. The narration guard can substitute the iOS voice for a chunk
    /// Supertonic garbled (#240), and that audio must not pass for Supertonic's (#311).
    public let engine: String
    /// Silence `SpeechSilenceTrim` cut from the model's audio before it was written (#586).
    public let trimmedSilence: TimeInterval

    public static let supertonicEngine = "supertonic"
    public static let systemVoiceEngine = "system_voice"

    /// How long the model made the chunk, silence included. The output check was tuned on this, so
    /// it judges this and not the shorter `duration`.
    public var modelDuration: TimeInterval { duration + trimmedSilence }

    public init(
        audioURL: URL,
        duration: TimeInterval,
        sampleRate: Int,
        renderDuration: TimeInterval,
        sessionLoadCount: Int,
        engine: String = SupertonicNarrationResult.supertonicEngine,
        trimmedSilence: TimeInterval = 0
    ) {
        self.audioURL = audioURL
        self.duration = duration
        self.sampleRate = sampleRate
        self.renderDuration = renderDuration
        self.sessionLoadCount = sessionLoadCount
        self.engine = engine
        self.trimmedSilence = trimmedSilence
    }
}

public enum SupertonicNarrationError: Error, LocalizedError, Equatable {
    case missingAsset(String)
    case emptyText
    case invalidSynthesisSteps(Int)
    case emptyAudio
    case unsafeAudio(String)

    public var errorDescription: String? {
        switch self {
        case .missingAsset(let name):
            return "Supertonic isn’t downloaded (\(name) is missing). Download it in Settings › Voices."
        case .emptyText:
            return "The text to speak is empty."
        case .invalidSynthesisSteps(let steps):
            return "Supertonic synthesis steps must be between 5 and 12; received \(steps)."
        case .emptyAudio:
            return "Supertonic generated no playable audio."
        case .unsafeAudio(let reason):
            return "Supertonic generated invalid audio: \(reason)."
        }
    }
}

/// A serial, reusable Supertonic runtime. The four ONNX sessions are loaded lazily
/// and retained across chunks until `unload()` is called.
public final class SupertonicNarrationRenderer: @unchecked Sendable {
    private final class RenderCancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private final class Runtime {
        let environment: ORTEnv
        let textToSpeech: TextToSpeech

        init(assets: SupertonicAssetLocation) throws {
            environment = try ORTEnv(loggingLevel: .warning)
            textToSpeech = try loadTextToSpeech(assets.onnxDirectoryURL.path, false, environment)
        }
    }

    private let assets: SupertonicAssetLocation
    private let outputDirectory: URL
    private let fileManager: FileManager
    private let renderQueue = DispatchQueue(label: "com.spokenmargins.supertonic.render", qos: .userInitiated)
    /// Paces inference in the background, for every on-device voice alike (#1679).
    public let governor: OnDeviceVoiceGovernor
    #if DEBUG
    /// Each inference step's pacing: who asked for the render and how long it was held back.
    var debugPacingRecords: [(pacing: SupertonicRenderPacing, delay: TimeInterval)] {
        governor.debugPacingRecords.map { ($0.pacing, $0.delay) }
    }
    #endif
    private var runtime: Runtime?
    private var sessionLoadCount = 0
    private var generatedAudioURLs: Set<URL> = []

    public init(
        assets: SupertonicAssetLocation,
        outputDirectory: URL,
        governor: OnDeviceVoiceGovernor,
        fileManager: FileManager = .default
    ) throws {
        try assets.validate(fileManager: fileManager)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        self.assets = assets
        self.outputDirectory = outputDirectory
        self.governor = governor
        self.fileManager = fileManager
    }

    /// Whether the app is in the background, on this renderer's governor (the app sets it on the shared governor).
    /// Background preparation asks for pacing per render instead (#377): it used to set and clear this shared flag,
    /// which paced live narration while a Library chunk rendered and switched pacing off in the background when a
    /// pass ended.
    public func setBackgroundInferencePacingEnabled(_ enabled: Bool) {
        governor.setAppBackgrounded(enabled)
    }

    public func render(
        text: String,
        voice: SupertonicVoiceID = .m2,
        language: String = "en",
        speed: Float = 1.0,
        synthesisSteps: Int = 8
    ) async throws -> SupertonicNarrationResult {
        try await render(text: text, voice: voice, language: language, speed: speed,
                         synthesisSteps: synthesisSteps, pacing: .whenAppBackgrounded)
    }

    public func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int,
        pacing: SupertonicRenderPacing
    ) async throws -> SupertonicNarrationResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw SupertonicNarrationError.emptyText }
        guard (5...12).contains(synthesisSteps) else {
            throw SupertonicNarrationError.invalidSynthesisSteps(synthesisSteps)
        }
        try Task.checkCancellation()

        let cancellation = RenderCancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                renderQueue.async { [self] in
                    // Drain Objective-C tensor temporaries after every chunk,
                    // rather than leaving them to the dispatch queue's pool.
                    autoreleasepool {
                        do {
                            guard !cancellation.isCancelled else { throw CancellationError() }
                            let startedAt = Date()
                            let runtime = try loadRuntimeIfNeeded()
                            let style = try loadVoiceStyle([assets.voiceStyleURL(for: voice).path], verbose: false)
                            let generated = try runtime.textToSpeech.call(
                                normalized,
                                language,
                                style,
                                synthesisSteps,
                                speed: max(0.7, min(2.0, speed)),
                                silenceDuration: 0.3,
                                runInference: Self.pacedInferenceStep(
                                    governor: governor, pacing: pacing, isCancelled: { cancellation.isCancelled })
                            )
                            guard !cancellation.isCancelled else { throw CancellationError() }
                            let sampleCount = min(
                                generated.wav.count,
                                max(0, Int(Float(runtime.textToSpeech.sampleRate) * generated.duration))
                            )
                            guard sampleCount > 0 else { throw SupertonicNarrationError.emptyAudio }
                            let samples = Array(generated.wav.prefix(sampleCount))
                            guard samples.allSatisfy(\.isFinite) else {
                                throw SupertonicNarrationError.unsafeAudio("non_finite_samples")
                            }
                            guard samples.lazy.map({ abs($0) }).max() ?? 0 > 0.000_001 else {
                                throw SupertonicNarrationError.unsafeAudio("silent_output")
                            }
                            // The model leaves about 0.6 s before the speech and 0.8 s after it, which
                            // made every chunk seam a stall (#586). Keep the speech and a short pad.
                            let sampleRate = runtime.textToSpeech.sampleRate
                            let kept = SpeechSilenceTrim.speechRange(in: samples, sampleRate: sampleRate)
                                .map { Array(samples[$0]) } ?? samples
                            let trimmedSilence = TimeInterval(samples.count - kept.count) / TimeInterval(sampleRate)
                            let audioURL = outputDirectory.appending(path: "supertonic-\(UUID().uuidString).wav")
                            try writeWavFile(audioURL.path, kept, sampleRate)
                            generatedAudioURLs.insert(audioURL)
                            continuation.resume(returning: SupertonicNarrationResult(
                                audioURL: audioURL,
                                duration: TimeInterval(generated.duration) - trimmedSilence,
                                sampleRate: sampleRate,
                                renderDuration: Date().timeIntervalSince(startedAt),
                                sessionLoadCount: sessionLoadCount,
                                trimmedSilence: trimmedSilence
                            ))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func unload(removingGeneratedAudio: Bool = true) async {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                runtime = nil
                if removingGeneratedAudio {
                    for url in generatedAudioURLs {
                        try? fileManager.removeItem(at: url)
                    }
                    generatedAudioURLs.removeAll()
                }
                continuation.resume()
            }
        }
    }

    /// Deletes `url` only if this renderer generated it. Callers also pass files they own, such as
    /// an article's durable prepared chunks or disk-cache entries, which must survive (#258).
    public func discardGeneratedAudio(at url: URL) async {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                if generatedAudioURLs.remove(url) != nil {
                    try? fileManager.removeItem(at: url)
                }
                continuation.resume()
            }
        }
    }

    public func diagnostics() async -> (sessionLoadCount: Int, generatedFileCount: Int) {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(returning: (sessionLoadCount, generatedAudioURLs.count))
            }
        }
    }

    private func loadRuntimeIfNeeded() throws -> Runtime {
        if let runtime { return runtime }
        let loaded = try Runtime(assets: assets)
        runtime = loaded
        sessionLoadCount += 1
        return loaded
    }

    /// What every model step of a render runs through: it is charged to the governor's shared budget in process CPU
    /// time, which Supertonic's ONNX threads push past wall time (#2695), then rests by the governor's pacing. A static
    /// function of the governor alone, so host tests drive it with a stub step, without the downloaded model.
    static func pacedInferenceStep(
        governor: OnDeviceVoiceGovernor, pacing: SupertonicRenderPacing, isCancelled: @escaping () -> Bool
    ) -> SupertonicInferenceStep {
        { inference in
            guard !isCancelled() else { throw CancellationError() }
            let (_, cost) = try governor.measureInference(inference)
            try governor.rest(after: cost, pacing: pacing) {
                guard !isCancelled() else { throw CancellationError() }
                return true
            }
            guard !isCancelled() else { throw CancellationError() }
        }
    }

    /// How long a render with `pacing` sleeps after `inferenceDuration` of inference, now.
    func pacingDelay(afterInferenceDuration inferenceDuration: TimeInterval, for pacing: SupertonicRenderPacing) -> TimeInterval {
        governor.pacingDelay(afterInference: inferenceDuration, for: pacing)
    }
}

/// Who a render is for, which decides whether its inference is paced (#377). Shared by every on-device voice (#1679).
public typealias SupertonicRenderPacing = OnDeviceRenderPacing
