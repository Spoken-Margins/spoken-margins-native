import Foundation
import SessionKit

public struct PocketNarrationResult: Equatable, Sendable {
    public let audioURL: URL
    public let duration: TimeInterval
    public let sampleRate: Int
    /// Wall time the render took, model load excluded.
    public let renderDuration: TimeInterval
    public let sessionLoadCount: Int
    public let engine: String

    public static let pocketEngine = "pocket"

    /// Seconds of speech made per second of rendering. Above 1 keeps ahead of playback.
    public var speedAgainstRealTime: Double { renderDuration > 0 ? duration / renderDuration : .infinity }
}

/// Renders text to a WAV file with Kyutai's Pocket TTS, through the onnxruntime the app already
/// links for Supertonic (#459). The shape is Supertonic's: one serial runtime loaded on first use,
/// `render` for one piece of text, task cancellation to stop it, `discardGeneratedAudio` to clean up.
/// Nothing in the app calls it yet.
public final class PocketNarrationRenderer: @unchecked Sendable {
    private final class CancellationToken: @unchecked Sendable {
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

    private let assets: PocketAssetLocation
    private let voice: PocketVoiceID
    private let outputDirectory: URL
    private let threads: Int
    private let fileManager: FileManager
    private let noiseSeed: UInt64?
    /// Paces inference in the background, for every on-device voice alike (#1679).
    public let governor: OnDeviceVoiceGovernor
    private let renderQueue = DispatchQueue(label: "com.spokenmargins.pocket.render", qos: .userInitiated)
    private var runtime: PocketRuntime?
    private var sessionLoadCount = 0
    private var generatedAudioURLs: Set<URL> = []
    /// When the next inference may start, from the last one's cost (#1679). Read and written on `renderQueue` only.
    private var nextInferenceNotBefore: TimeInterval?

    /// `threads` is onnxruntime's thread count inside one network call. One keeps the phone cool;
    /// the model's own reference uses up to four. `noiseSeed` makes a render repeat exactly.
    public init(
        assets: PocketAssetLocation,
        outputDirectory: URL,
        voice: PocketVoiceID = .alba,
        threads: Int = 1,
        noiseSeed: UInt64? = nil,
        governor: OnDeviceVoiceGovernor,
        fileManager: FileManager = .default
    ) throws {
        try assets.validate(voice: voice, fileManager: fileManager)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        self.assets = assets
        self.voice = voice
        self.outputDirectory = outputDirectory
        self.threads = threads
        self.noiseSeed = noiseSeed
        self.governor = governor
        self.fileManager = fileManager
    }

    public func render(text: String) async throws -> PocketNarrationResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PocketNarrationError.emptyText
        }
        try Task.checkCancellation()

        let cancellation = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                renderQueue.async { [self] in
                    autoreleasepool {
                        do {
                            // The rest the last inference earned, as for Kitten (#1679).
                            // The shared background budget can hold even the first inference (#2695).
                            try governor.waitForNextInference(notBefore: nextInferenceNotBefore, pacing: .whenAppBackgrounded) {
                                guard !cancellation.isCancelled else { throw CancellationError() }
                                return true
                            }
                            nextInferenceNotBefore = nil
                            guard !cancellation.isCancelled else { throw CancellationError() }
                            let runtime = try loadRuntimeIfNeeded()
                            // Load time is paid once and reported apart from the render.
                            let startedAt = Date()
                            var noise = PocketNoise(seed: noiseSeed)
                            let (samples, inferenceCost) = try governor.measureInference {
                                try runtime.render(text: text, noise: &noise) { cancellation.isCancelled }
                            }
                            nextInferenceNotBefore = governor.nextInference(after: inferenceCost, pacing: .whenAppBackgrounded)
                            let renderDuration = Date().timeIntervalSince(startedAt)
                            guard !cancellation.isCancelled else { throw CancellationError() }

                            guard !samples.isEmpty else { throw PocketNarrationError.emptyAudio }
                            guard samples.allSatisfy(\.isFinite) else { throw PocketNarrationError.unsafeAudio("non_finite_samples") }
                            guard samples.lazy.map({ abs($0) }).max() ?? 0 > 0.000_001 else {
                                throw PocketNarrationError.unsafeAudio("silent_output")
                            }
                            let sampleRate = runtime.bundle.sampleRate
                            let audioURL = outputDirectory.appending(path: "pocket-\(UUID().uuidString).wav")
                            try Self.writeWAV(samples, sampleRate: sampleRate, to: audioURL)
                            generatedAudioURLs.insert(audioURL)
                            continuation.resume(returning: PocketNarrationResult(
                                audioURL: audioURL,
                                duration: TimeInterval(samples.count) / TimeInterval(sampleRate),
                                sampleRate: sampleRate,
                                renderDuration: renderDuration,
                                sessionLoadCount: sessionLoadCount,
                                engine: PocketNarrationResult.pocketEngine
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

    /// Drops the loaded networks, which hold most of the renderer's memory.
    public func unload(removingGeneratedAudio: Bool = false) async {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                runtime = nil
                if removingGeneratedAudio {
                    for url in generatedAudioURLs { try? fileManager.removeItem(at: url) }
                    generatedAudioURLs.removeAll()
                }
                continuation.resume()
            }
        }
    }

    /// Deletes `url` only if this renderer made it.
    public func discardGeneratedAudio(at url: URL) async {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                if generatedAudioURLs.remove(url) != nil { try? fileManager.removeItem(at: url) }
                continuation.resume()
            }
        }
    }

    /// Loads the networks ahead of the first render, so a measurement or a caller can pay for it
    /// separately. Returns the seconds it took, zero when they were already loaded.
    @discardableResult
    public func preload() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                do {
                    let started = Date()
                    let wasLoaded = runtime != nil
                    _ = try loadRuntimeIfNeeded()
                    continuation.resume(returning: wasLoaded ? 0 : Date().timeIntervalSince(started))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadRuntimeIfNeeded() throws -> PocketRuntime {
        if let runtime { return runtime }
        let loaded = try PocketRuntime(assets: assets, voice: voice, threads: threads)
        runtime = loaded
        sessionLoadCount += 1
        return loaded
    }

    static func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataSize = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32767))
        }
        try data.write(to: url, options: .atomic)
    }
}
