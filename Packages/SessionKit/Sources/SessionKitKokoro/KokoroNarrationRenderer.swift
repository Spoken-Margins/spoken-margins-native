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

public struct KokoroMemorySnapshot: Equatable, Sendable, CustomStringConvertible {
    public var activeMemory: Int
    public var cacheMemory: Int
    public var peakMemory: Int

    public init(activeMemory: Int, cacheMemory: Int, peakMemory: Int) {
        self.activeMemory = activeMemory
        self.cacheMemory = cacheMemory
        self.peakMemory = peakMemory
    }

    public var description: String {
        "active=\(Self.megabytes(activeMemory)) cache=\(Self.megabytes(cacheMemory)) peak=\(Self.megabytes(peakMemory))"
    }

    private static func megabytes(_ bytes: Int) -> String {
        "\(bytes / (1024 * 1024))MB"
    }
}

public enum KokoroNarrationError: Error, LocalizedError, Equatable {
    case unavailableOnSimulator
    case missingModel
    case missingVoices
    case missingVoice(String)
    case emptyText
    case emptyAudio
    case unsafeAudio(String)
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
            return "Kokoro rendered no audio samples."
        case .unsafeAudio(let reason):
            return "Kokoro rendered unsafe audio: \(reason)."
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

    private let engine: KokoroTTS
    private let voices: [String: MLXArray]
    private let outputDirectory: URL

    public static var isRuntimeSupported: Bool { true }

    public static func configureMemoryForDiagnostics(cacheLimitBytes: Int = 256 * 1024 * 1024) -> KokoroMemorySnapshot {
        Memory.cacheLimit = cacheLimitBytes
        Memory.clearCache()
        return memorySnapshot()
    }

    public static func clearMemoryCache() -> KokoroMemorySnapshot {
        Memory.clearCache()
        return memorySnapshot()
    }

    public static func memorySnapshot() -> KokoroMemorySnapshot {
        let snapshot = Memory.snapshot()
        return KokoroMemorySnapshot(
            activeMemory: snapshot.activeMemory,
            cacheMemory: snapshot.cacheMemory,
            peakMemory: snapshot.peakMemory
        )
    }

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
        self.engine = KokoroTTS(modelPath: modelURL)
        self.voices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
        self.outputDirectory = outputDirectory
        if voices.isEmpty {
            throw KokoroNarrationError.missingVoices
        }
    }

    public var availableVoiceNames: [String] {
        voices.keys
            .map { key in key.replacingOccurrences(of: ".npy", with: "") }
            .sorted()
    }

    public func render(
        text: String,
        itemId: String,
        chunkId: String,
        voiceName: String = defaultVoiceName,
        speed: Float = 1.0
    ) throws -> KokoroNarrationResult {
        let normalized = SpeechTextNormalizer.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw KokoroNarrationError.emptyText
        }
        let voiceKey = voiceName.hasSuffix(".npy") ? voiceName : "\(voiceName).npy"
        guard let voice = voices[voiceKey] else {
            throw KokoroNarrationError.missingVoice(voiceName)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let language: Language = voiceName.first == "b" ? .enGB : .enUS
        let startedAt = Date()
        let (samples, tokens) = try engine.generateAudio(
            voice: voice,
            language: language,
            text: normalized,
            speed: speed
        )
        let playableSamples = try Self.sanitizedAudioSamples(samples)
        guard !playableSamples.isEmpty else {
            throw KokoroNarrationError.emptyAudio
        }
        let safeName = [itemId, chunkId, voiceName]
            .joined(separator: "-")
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
        let audioURL = outputDirectory.appending(path: "\(safeName)-\(UUID().uuidString).caf")
        try? FileManager.default.removeItem(at: audioURL)
        try writeAudio(samples: playableSamples, to: audioURL)
        let duration = Double(playableSamples.count) / Self.sampleRate
        let renderDuration = Date().timeIntervalSince(startedAt)
        _ = renderDuration
        return KokoroNarrationResult(
            audioURL: audioURL,
            sampleRate: Self.sampleRate,
            duration: duration,
            tokenCount: tokens?.count ?? 0
        )
    }

    private func writeAudio(samples: [Float], to audioURL: URL) throws {
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

    private static func sanitizedAudioSamples(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        var output = samples.map { sample -> Float in
            guard sample.isFinite else { return 0 }
            return min(0.98, max(-0.98, sample))
        }
        let mean = output.reduce(Float(0), +) / Float(output.count)
        if abs(mean) > 0.001 {
            output = output.map { min(0.98, max(-0.98, $0 - mean)) }
        }
        try rejectUnsafeAudio(output)
        output = speechBandLimited(output)
        let fadeCount = min(output.count / 2, max(1, Int(Self.sampleRate * 0.005)))
        guard fadeCount > 1 else { return output }
        for index in 0..<fadeCount {
            let scale = Float(index) / Float(fadeCount)
            output[index] *= scale
            output[output.count - 1 - index] *= scale
        }
        return output
    }

    private static func rejectUnsafeAudio(_ samples: [Float]) throws {
        guard samples.count > 256 else { return }
        let meanAbs = samples.reduce(Float(0)) { $0 + abs($1) } / Float(samples.count)
        guard meanAbs > 0.0005 else { return }
        var zeroCrossings = 0
        var totalDelta = Float(0)
        var peak = Float(0)
        var previous = samples[0]
        for sample in samples.dropFirst() {
            if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) {
                zeroCrossings += 1
            }
            totalDelta += abs(sample - previous)
            peak = max(peak, abs(sample))
            previous = sample
        }
        let zeroCrossingRate = Float(zeroCrossings) / Float(samples.count - 1)
        let derivativeRatio = (totalDelta / Float(samples.count - 1)) / meanAbs
        if peak > 0.95 && zeroCrossingRate > 0.28 && derivativeRatio > 1.05 {
            throw KokoroNarrationError.unsafeAudio("high_frequency_spike")
        }
        if zeroCrossingRate > 0.42 && derivativeRatio > 1.25 {
            throw KokoroNarrationError.unsafeAudio("pathological_high_frequency")
        }
    }

    private static func speechBandLimited(_ samples: [Float]) -> [Float] {
        var filtered = samples
        for frequency in [4_200.0, 4_800.0, 5_600.0, 6_400.0, 7_200.0, 8_400.0, 9_600.0, 10_800.0] {
            filtered = notchFiltered(filtered, frequency: frequency, quality: 18)
        }
        for _ in 0..<4 {
            filtered = onePoleLowPass(filtered, cutoff: 4_800)
        }
        return filtered.map { min(0.98, max(-0.98, $0)) }
    }

    private static func onePoleLowPass(_ samples: [Float], cutoff: Double) -> [Float] {
        guard var previous = samples.first else { return samples }
        let dt = 1.0 / Self.sampleRate
        let rc = 1.0 / (2.0 * Double.pi * cutoff)
        let alpha = Float(dt / (rc + dt))
        return samples.map { sample in
            previous += alpha * (sample - previous)
            return previous
        }
    }

    private static func notchFiltered(_ samples: [Float], frequency: Double, quality: Double) -> [Float] {
        guard !samples.isEmpty, frequency > 0, frequency < Self.sampleRate / 2 else { return samples }
        let omega = 2.0 * Double.pi * frequency / Self.sampleRate
        let alpha = sin(omega) / (2.0 * quality)
        let b0 = 1.0
        let b1 = -2.0 * cos(omega)
        let b2 = 1.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cos(omega)
        let a2 = 1.0 - alpha

        let nb0 = Float(b0 / a0)
        let nb1 = Float(b1 / a0)
        let nb2 = Float(b2 / a0)
        let na1 = Float(a1 / a0)
        let na2 = Float(a2 / a0)

        var x1 = Float(0)
        var x2 = Float(0)
        var y1 = Float(0)
        var y2 = Float(0)
        return samples.map { x0 in
            let y0 = nb0 * x0 + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
            return y0
        }
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

    public static func configureMemoryForDiagnostics(cacheLimitBytes: Int = 256 * 1024 * 1024) -> KokoroMemorySnapshot {
        KokoroMemorySnapshot(activeMemory: 0, cacheMemory: 0, peakMemory: 0)
    }

    public static func clearMemoryCache() -> KokoroMemorySnapshot {
        KokoroMemorySnapshot(activeMemory: 0, cacheMemory: 0, peakMemory: 0)
    }

    public static func memorySnapshot() -> KokoroMemorySnapshot {
        KokoroMemorySnapshot(activeMemory: 0, cacheMemory: 0, peakMemory: 0)
    }

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
