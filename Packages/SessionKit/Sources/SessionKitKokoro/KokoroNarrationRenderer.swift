import Foundation
import SessionKit

public struct KokoroAssetLocation: Equatable, Sendable {
    public var modelURL: URL?
    public var voicesURL: URL?

    public init(modelURL: URL?, voicesURL: URL?) {
        self.modelURL = modelURL
        self.voicesURL = voicesURL
    }
}

public struct KokoroNarrationResult: Equatable, Sendable {
    public var audioURL: URL
    public var sampleRate: Double
    public var duration: Double
    public var tokenCount: Int

    public init(audioURL: URL, sampleRate: Double, duration: Double, tokenCount: Int) {
        self.audioURL = audioURL
        self.sampleRate = sampleRate
        self.duration = duration
        self.tokenCount = tokenCount
    }
}

public struct KokoroNarrationBuffer: Equatable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: Double
    public var tokenCount: Int

    public init(samples: [Float], sampleRate: Double, duration: Double, tokenCount: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
        self.tokenCount = tokenCount
    }
}

public enum KokoroNarrationError: Error, LocalizedError, Equatable {
    case unavailableOnSimulator
    case missingModel
    case missingVoices
    case missingVoice(String)
    case emptyText
    case emptyAudio
    case textTooLong
    case cannotCreateAudioFormat
    case cannotCreateAudioBuffer

    public var errorDescription: String? {
        switch self {
        case .unavailableOnSimulator:
            return "Kokoro rendering is only available on device in this build."
        case .missingModel:
            return "Kokoro model missing. Import kokoro-v1_0.safetensors in Settings."
        case .missingVoices:
            return "Kokoro voices missing. Import voices.npz in Settings."
        case .missingVoice(let voice):
            return "Kokoro voice \(voice) was not found in voices.npz."
        case .emptyText:
            return "Kokoro preview text is empty."
        case .emptyAudio:
            return "Kokoro generated no audio for this text."
        case .textTooLong:
            return "Kokoro text chunk is too long. Try a shorter chunk."
        case .cannotCreateAudioFormat:
            return "Kokoro could not create an audio format."
        case .cannotCreateAudioBuffer:
            return "Kokoro could not create an audio buffer."
        }
    }
}

#if canImport(KokoroSwift) && canImport(MLX) && canImport(MLXUtilsLibrary) && canImport(AVFoundation) && !targetEnvironment(simulator)
import AVFoundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

public final class KokoroNarrationRenderer {
    public static let modelResourceName = "kokoro-v1_0"
    public static let modelResourceExtension = "safetensors"
    public static let voicesResourceName = "voices"
    public static let voicesResourceExtension = "npz"
    public static let defaultVoiceName = "am_echo"
    public static let sampleRate = Double(KokoroTTS.Constants.samplingRate)

    private let runtime: KokoroRuntime
    private let outputDirectory: URL
    private static let runtimeCache = KokoroRuntimeCache()

    public static var isRuntimeSupported: Bool { true }

    public static func bundledAssets(in bundle: Bundle = .main) -> KokoroAssetLocation {
        KokoroAssetLocation(
            modelURL: bundle.url(forResource: modelResourceName, withExtension: modelResourceExtension),
            voicesURL: bundle.url(forResource: voicesResourceName, withExtension: voicesResourceExtension)
        )
    }

    public static func installedAssets(
        in bundle: Bundle = .main,
        applicationSupportDirectory: URL?,
        fileManager: FileManager = .default
    ) -> KokoroAssetLocation {
        let bundled = bundledAssets(in: bundle)
        let supportDirectory = applicationSupportDirectory?.appending(path: "Kokoro", directoryHint: .isDirectory)
        let supportModelURL = supportDirectory?.appending(path: "\(modelResourceName).\(modelResourceExtension)")
        let supportVoicesURL = supportDirectory?.appending(path: "\(voicesResourceName).\(voicesResourceExtension)")
        return KokoroAssetLocation(
            modelURL: bundled.modelURL ?? existingFileURL(supportModelURL, fileManager: fileManager),
            voicesURL: bundled.voicesURL ?? existingFileURL(supportVoicesURL, fileManager: fileManager)
        )
    }

    private static func existingFileURL(_ url: URL?, fileManager: FileManager) -> URL? {
        guard let url, fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public init(modelURL: URL, voicesURL: URL, outputDirectory: URL) throws {
        self.runtime = try Self.runtime(modelURL: modelURL, voicesURL: voicesURL)
        self.outputDirectory = outputDirectory
    }

    public var availableVoiceNames: [String] {
        runtime.voices.keys
            .map { key in key.replacingOccurrences(of: ".npy", with: "") }
            .sorted()
    }

    public func renderSamples(
        text: String,
        voiceName: String = defaultVoiceName,
        speed: Float = 1.0
    ) throws -> KokoroNarrationBuffer {
        try runtime.renderSamples(text: text, voiceName: voiceName, speed: speed)
    }

    public func render(
        text: String,
        itemId: String,
        chunkId: String,
        voiceName: String = defaultVoiceName,
        speed: Float = 1.0
    ) throws -> KokoroNarrationResult {
        let buffer = try renderSamples(text: text, voiceName: voiceName, speed: speed)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let safeName = [itemId, chunkId, voiceName]
            .joined(separator: "-")
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
        let audioURL = outputDirectory.appending(path: "\(safeName).caf")
        try writeAudio(samples: buffer.samples, to: audioURL)
        return KokoroNarrationResult(
            audioURL: audioURL,
            sampleRate: buffer.sampleRate,
            duration: buffer.duration,
            tokenCount: buffer.tokenCount
        )
    }

    private static func runtime(modelURL: URL, voicesURL: URL) throws -> KokoroRuntime {
        try runtimeCache.runtime(modelURL: modelURL, voicesURL: voicesURL)
    }

    private func writeAudio(samples: [Float], to audioURL: URL) throws {
        guard !samples.isEmpty else {
            throw KokoroNarrationError.emptyAudio
        }
        let frameCount = AVAudioFrameCount(samples.count)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw KokoroNarrationError.cannotCreateAudioFormat
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw KokoroNarrationError.cannotCreateAudioBuffer
        }
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                channel.update(from: baseAddress, count: source.count)
            }
        }
        let audioFile = try AVAudioFile(
            forWriting: audioURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try audioFile.write(from: buffer)
    }
}

private final class KokoroRuntimeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedRuntime: KokoroRuntime?

    func runtime(modelURL: URL, voicesURL: URL) throws -> KokoroRuntime {
        lock.lock()
        defer { lock.unlock() }
        if let cachedRuntime,
           cachedRuntime.modelURL == modelURL,
           cachedRuntime.voicesURL == voicesURL {
            return cachedRuntime
        }
        let runtime = try KokoroRuntime(modelURL: modelURL, voicesURL: voicesURL)
        cachedRuntime = runtime
        return runtime
    }
}

private final class KokoroRuntime {
    let modelURL: URL
    let voicesURL: URL
    let engine: KokoroTTS
    let voices: [String: MLXArray]
    private let renderLock = NSLock()

    init(modelURL: URL, voicesURL: URL) throws {
        self.modelURL = modelURL
        self.voicesURL = voicesURL
        self.engine = KokoroTTS(modelPath: modelURL)
        self.voices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
        if voices.isEmpty {
            throw KokoroNarrationError.missingVoices
        }
    }

    func renderSamples(
        text: String,
        voiceName: String,
        speed: Float
    ) throws -> KokoroNarrationBuffer {
        let normalized = SpeechTextNormalizer.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw KokoroNarrationError.emptyText
        }
        let voiceKey = voiceName.hasSuffix(".npy") ? voiceName : "\(voiceName).npy"
        guard let voice = voices[voiceKey] else {
            throw KokoroNarrationError.missingVoice(voiceName)
        }
        let language: Language = voiceName.first == "b" ? .enGB : .enUS
        let samples: [Float]
        let tokens: [MToken]?
        do {
            renderLock.lock()
            defer { renderLock.unlock() }
            (samples, tokens) = try engine.generateAudio(
                voice: voice,
                language: language,
                text: normalized,
                speed: speed
            )
        } catch KokoroTTS.KokoroTTSError.tooManyTokens {
            throw KokoroNarrationError.textTooLong
        }
        guard !samples.isEmpty else {
            throw KokoroNarrationError.emptyAudio
        }
        return KokoroNarrationBuffer(
            samples: samples,
            sampleRate: KokoroNarrationRenderer.sampleRate,
            duration: Double(samples.count) / KokoroNarrationRenderer.sampleRate,
            tokenCount: tokens?.count ?? 0
        )
    }
}
#else
public final class KokoroNarrationRenderer {
    public static let modelResourceName = "kokoro-v1_0"
    public static let modelResourceExtension = "safetensors"
    public static let voicesResourceName = "voices"
    public static let voicesResourceExtension = "npz"
    public static let defaultVoiceName = "am_echo"
    public static let sampleRate = 24_000.0

    public static var isRuntimeSupported: Bool { false }

    public static func bundledAssets(in bundle: Bundle = .main) -> KokoroAssetLocation {
        KokoroAssetLocation(
            modelURL: bundle.url(forResource: modelResourceName, withExtension: modelResourceExtension),
            voicesURL: bundle.url(forResource: voicesResourceName, withExtension: voicesResourceExtension)
        )
    }

    public static func installedAssets(
        in bundle: Bundle = .main,
        applicationSupportDirectory: URL?,
        fileManager: FileManager = .default
    ) -> KokoroAssetLocation {
        let bundled = bundledAssets(in: bundle)
        let supportDirectory = applicationSupportDirectory?.appending(path: "Kokoro", directoryHint: .isDirectory)
        let supportModelURL = supportDirectory?.appending(path: "\(modelResourceName).\(modelResourceExtension)")
        let supportVoicesURL = supportDirectory?.appending(path: "\(voicesResourceName).\(voicesResourceExtension)")
        return KokoroAssetLocation(
            modelURL: bundled.modelURL ?? existingFileURL(supportModelURL, fileManager: fileManager),
            voicesURL: bundled.voicesURL ?? existingFileURL(supportVoicesURL, fileManager: fileManager)
        )
    }

    private static func existingFileURL(_ url: URL?, fileManager: FileManager) -> URL? {
        guard let url, fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public init(modelURL: URL, voicesURL: URL, outputDirectory: URL) throws {
        throw KokoroNarrationError.unavailableOnSimulator
    }

    public var availableVoiceNames: [String] { [] }

    public func renderSamples(
        text: String,
        voiceName: String = defaultVoiceName,
        speed: Float = 1.0
    ) throws -> KokoroNarrationBuffer {
        throw KokoroNarrationError.unavailableOnSimulator
    }

    public func render(
        text: String,
        itemId: String,
        chunkId: String,
        voiceName: String = defaultVoiceName,
        speed: Float = 1.0
    ) throws -> KokoroNarrationResult {
        throw KokoroNarrationError.unavailableOnSimulator
    }
}
#endif
