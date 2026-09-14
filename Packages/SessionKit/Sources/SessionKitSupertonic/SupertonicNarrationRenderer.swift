import Foundation
import OnnxRuntimeBindings

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
    public let duration: TimeInterval
    public let sampleRate: Int
    public let renderDuration: TimeInterval
    public let sessionLoadCount: Int

    public init(
        audioURL: URL,
        duration: TimeInterval,
        sampleRate: Int,
        renderDuration: TimeInterval,
        sessionLoadCount: Int
    ) {
        self.audioURL = audioURL
        self.duration = duration
        self.sampleRate = sampleRate
        self.renderDuration = renderDuration
        self.sessionLoadCount = sessionLoadCount
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
            return "Bundled Supertonic asset is missing: \(name)."
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
    private let inferencePacingLock = NSLock()
    private var backgroundInferencePacingEnabled = false
    private var runtime: Runtime?
    private var sessionLoadCount = 0
    private var generatedAudioURLs: Set<URL> = []

    public init(
        assets: SupertonicAssetLocation,
        outputDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try assets.validate(fileManager: fileManager)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        self.assets = assets
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
    }

    /// Keeps full-item generation running while the app is backgrounded without
    /// exceeding iOS's sustained CPU budget for background audio processes.
    /// Foreground synthesis remains unthrottled so the initial two chunks start
    /// as quickly as possible.
    public func setBackgroundInferencePacingEnabled(_ enabled: Bool) {
        inferencePacingLock.lock()
        backgroundInferencePacingEnabled = enabled
        inferencePacingLock.unlock()
    }

    public func render(
        text: String,
        voice: SupertonicVoiceID = .m2,
        language: String = "en",
        speed: Float = 1.0,
        synthesisSteps: Int = 8
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
                                paceAfterInference: { [weak self] inferenceDuration in
                                    guard !cancellation.isCancelled else { throw CancellationError() }
                                    self?.paceBackgroundInference(after: inferenceDuration)
                                    guard !cancellation.isCancelled else { throw CancellationError() }
                                }
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
                            let audioURL = outputDirectory.appending(path: "supertonic-\(UUID().uuidString).wav")
                            try writeWavFile(audioURL.path, samples, runtime.textToSpeech.sampleRate)
                            generatedAudioURLs.insert(audioURL)
                            continuation.resume(returning: SupertonicNarrationResult(
                                audioURL: audioURL,
                                duration: TimeInterval(generated.duration),
                                sampleRate: runtime.textToSpeech.sampleRate,
                                renderDuration: Date().timeIntervalSince(startedAt),
                                sessionLoadCount: sessionLoadCount
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

    public func discardGeneratedAudio(at url: URL) async {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                try? fileManager.removeItem(at: url)
                generatedAudioURLs.remove(url)
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

    private func paceBackgroundInference(after inferenceDuration: TimeInterval) {
        var remaining = SupertonicInferencePacingPolicy.delay(
            afterInferenceDuration: inferenceDuration,
            backgrounded: isBackgroundInferencePacingEnabled
        )
        while remaining > 0 {
            guard isBackgroundInferencePacingEnabled else { return }
            let interval = min(0.1, remaining)
            Thread.sleep(forTimeInterval: interval)
            remaining -= interval
        }
    }

    private var isBackgroundInferencePacingEnabled: Bool {
        inferencePacingLock.lock()
        defer { inferencePacingLock.unlock() }
        return backgroundInferencePacingEnabled
    }
}

enum SupertonicInferencePacingPolicy {
    /// ONNX occupied roughly 85% of one CPU in the device termination traces.
    /// Holding inference work to 65% of wall time leaves margin below iOS's 80%
    /// sustained-background limit for playback and application bookkeeping.
    static let backgroundWorkDutyCycle = 0.65

    static func delay(afterInferenceDuration duration: TimeInterval, backgrounded: Bool) -> TimeInterval {
        guard backgrounded, duration > 0 else { return 0 }
        return duration * ((1 / backgroundWorkDutyCycle) - 1)
    }
}
