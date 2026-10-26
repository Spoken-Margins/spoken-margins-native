import Foundation
import OnnxRuntimeBindings
import SessionKit
import SessionKitSpeechFrontEnd

/// Where the bundled Kitten voice's files are (`App/SpokenMarginsApp/Resources/Kitten`).
public struct KittenAssetLocation: Equatable, Sendable {
    public let rootURL: URL

    public init(rootURL: URL) { self.rootURL = rootURL }

    public var modelURL: URL { rootURL.appending(path: "kitten_tts_nano_v0_8.onnx") }
    public var lexiconURL: URL { rootURL.appending(path: "lexicon.tsv") }
    public var g2pWeightsURL: URL { rootURL.appending(path: "g2p_weights.bin") }
    public var g2pManifestURL: URL { rootURL.appending(path: "g2p_weights.json") }
    public var voiceURL: URL { rootURL.appending(path: "voice.f32") }

    public func validate(fileManager: FileManager = .default) throws {
        for url in [modelURL, lexiconURL, g2pWeightsURL, g2pManifestURL, voiceURL]
        where !fileManager.fileExists(atPath: url.path) {
            throw KittenNarrationError.missingAsset(url.lastPathComponent)
        }
    }
}

public enum KittenNarrationError: Error, LocalizedError, Equatable {
    case missingAsset(String)
    case emptyText
    case emptyAudio
    case unsafeAudio(String)

    public var errorDescription: String? {
        switch self {
        case .missingAsset(let name): "Bundled Kitten asset is missing: \(name)."
        case .emptyText: "The text to speak is empty."
        case .emptyAudio: "Kitten generated no playable audio."
        case .unsafeAudio(let reason): "Kitten generated invalid audio: \(reason)."
        }
    }
}

/// The bundled fallback voice: KittenTTS nano 0.8 (fp32, Apache-2.0) with the voice "Jasper", reading
/// text through `KittenFrontEnd`. It stands in for Supertonic when `SupertonicResourcePolicy` refuses
/// to render (heat, memory pressure), at about 6x real time on the owner's iPhone 17 Pro in Low Power
/// Mode (C2 M2, #192). One serial queue, one ONNX session, loaded on first use and kept until `unload()`.
/// Its inference is paced by the shared `OnDeviceVoiceGovernor`, as Supertonic's is (#1679).
public final class KittenNarrationRenderer: @unchecked Sendable {
    public static let engine = "kitten"
    public static let sampleRate = 24_000
    /// The model ends every waveform with this many samples of noise-free tail to cut (Kitten's own wrapper does).
    static let tailSamples = 5_000
    /// Jasper's speed prior from the model's config.
    static let speed: Float = 0.8
    static let styleRowCount = 400
    static let styleWidth = 256

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private final class Runtime {
        let environment: ORTEnv
        let session: ORTSession
        let frontEnd: KittenFrontEnd
        let styleRows: [Float]

        init(assets: KittenAssetLocation, threads: Int32) throws {
            environment = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(threads)
            try options.setGraphOptimizationLevel(.all)
            session = try ORTSession(env: environment, modelPath: assets.modelURL.path, sessionOptions: options)
            frontEnd = try KittenFrontEnd(lexiconURL: assets.lexiconURL, g2pWeightsURL: assets.g2pWeightsURL,
                                          g2pManifestURL: assets.g2pManifestURL)
            let voice = try Data(contentsOf: assets.voiceURL)
            var rows = [Float](repeating: 0, count: KittenNarrationRenderer.styleRowCount * KittenNarrationRenderer.styleWidth)
            guard voice.count == rows.count * MemoryLayout<Float>.size else {
                throw KittenNarrationError.missingAsset(assets.voiceURL.lastPathComponent)
            }
            rows.withUnsafeMutableBytes { _ = voice.copyBytes(to: $0) }
            styleRows = rows
        }
    }

    private let assets: KittenAssetLocation
    private let outputDirectory: URL
    private let fileManager: FileManager
    private let threads: Int32
    /// Paces inference in the background, for every on-device voice alike (#1679).
    public let governor: OnDeviceVoiceGovernor
    private let renderQueue = DispatchQueue(label: "com.spokenmargins.kitten.render", qos: .userInitiated)
    private var runtime: Runtime?
    private var sessionLoadCount = 0
    private var generatedAudioURLs: Set<URL> = []
    /// When the next inference may start, from the last one's cost (#1679). Read and written on `renderQueue` only.
    private var nextInferenceNotBefore: TimeInterval?

    /// Two threads measured 6.7x against 5.8x on one (C2 M2), and leave the rest of the CPU to playback.
    /// `governor` paces inference in the background; the app passes its one shared governor.
    public init(
        assets: KittenAssetLocation, outputDirectory: URL, threads: Int = 2,
        governor: OnDeviceVoiceGovernor, fileManager: FileManager = .default
    ) throws {
        try assets.validate(fileManager: fileManager)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        self.assets = assets
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
        self.threads = Int32(max(1, threads))
        self.governor = governor
    }

    /// Kitten's input ids and the style row Kitten's own wrapper picks: the row at the text's length in
    /// characters, capped at the last. Exposed for the benchmark and the tests.
    public static func styleRowIndex(forText text: String) -> Int {
        min(text.unicodeScalars.count, styleRowCount - 1)
    }

    /// Live narration: paced only while the app is in the background.
    public func render(text: String) async throws -> SupertonicNarrationResult {
        try await render(text: text, pacing: .whenAppBackgrounded)
    }

    public func render(text: String, pacing: OnDeviceRenderPacing) async throws -> SupertonicNarrationResult {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw KittenNarrationError.emptyText }
        try Task.checkCancellation()
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                renderQueue.async { [self] in
                    autoreleasepool {
                        do {
                            // The rest the last inference earned, waited out here under this render's own pacing and
                            // cancellation: in the background Kitten stays under iOS's CPU limit, which it ran
                            // straight past before (#1679), and a chunk is never held back once it is made.
                            // The shared background budget can hold even the first inference (#2695).
                            try governor.waitForNextInference(notBefore: nextInferenceNotBefore, pacing: pacing) {
                                guard !cancellation.isCancelled else { throw CancellationError() }
                                return true
                            }
                            nextInferenceNotBefore = nil
                            guard !cancellation.isCancelled else { throw CancellationError() }
                            let startedAt = Date()
                            // Loading the session is paid once and isn't counted as inference.
                            let runtime = try loadRuntimeIfNeeded()
                            let (samples, cost) = try governor.measureInference { try synthesize(spoken, with: runtime) }
                            nextInferenceNotBefore = governor.nextInference(after: cost, pacing: pacing)
                            let rate = Self.sampleRate
                            let kept = SpeechSilenceTrim.speechRange(in: samples, sampleRate: rate).map { Array(samples[$0]) } ?? samples
                            let trimmedSilence = TimeInterval(samples.count - kept.count) / TimeInterval(rate)
                            let audioURL = outputDirectory.appending(path: "kitten-\(UUID().uuidString).wav")
                            try writeWavFile(audioURL.path, kept, rate)
                            generatedAudioURLs.insert(audioURL)
                            continuation.resume(returning: SupertonicNarrationResult(
                                audioURL: audioURL,
                                duration: TimeInterval(kept.count) / TimeInterval(rate),
                                sampleRate: rate,
                                renderDuration: Date().timeIntervalSince(startedAt),
                                sessionLoadCount: sessionLoadCount,
                                engine: Self.engine,
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

    /// The waveform for `text`, 24 kHz mono, with the model's tail cut.
    private func synthesize(_ text: String, with runtime: Runtime) throws -> [Float] {
        var ids = runtime.frontEnd.inputIDs(for: text)
        let row = Self.styleRowIndex(forText: text) * Self.styleWidth
        var style = Array(runtime.styleRows[row..<(row + Self.styleWidth)])
        var speed = Self.speed
        let idsValue = try ORTValue(
            tensorData: NSMutableData(bytes: &ids, length: ids.count * MemoryLayout<Int64>.size),
            elementType: .int64, shape: [1, NSNumber(value: ids.count)])
        let styleValue = try ORTValue(
            tensorData: NSMutableData(bytes: &style, length: style.count * MemoryLayout<Float>.size),
            elementType: .float, shape: [1, NSNumber(value: style.count)])
        let speedValue = try ORTValue(
            tensorData: NSMutableData(bytes: &speed, length: MemoryLayout<Float>.size),
            elementType: .float, shape: [1])
        let outputs = try runtime.session.run(
            withInputs: ["input_ids": idsValue, "style": styleValue, "speed": speedValue],
            outputNames: ["waveform"], runOptions: nil)
        guard let waveform = outputs["waveform"] else { throw KittenNarrationError.emptyAudio }
        let data = try waveform.tensorData() as Data
        let total = data.count / MemoryLayout<Float>.size
        guard total > Self.tailSamples else { throw KittenNarrationError.emptyAudio }
        let kept = total - Self.tailSamples
        var samples = [Float](repeating: 0, count: kept)
        samples.withUnsafeMutableBytes { _ = data.copyBytes(to: $0, from: 0..<(kept * MemoryLayout<Float>.size)) }
        guard samples.allSatisfy(\.isFinite) else { throw KittenNarrationError.unsafeAudio("non_finite_samples") }
        guard samples.lazy.map({ abs($0) }).max() ?? 0 > 0.000_001 else { throw KittenNarrationError.unsafeAudio("silent_output") }
        return samples
    }

    /// Drops the ONNX session and the lexicon mapping, and by default the audio this renderer wrote.
    public func unload(removingGeneratedAudio: Bool = true) async {
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

    /// Deletes `url` only if this renderer wrote it (callers also pass files other renderers own).
    public func discardGeneratedAudio(at url: URL) async {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                if generatedAudioURLs.remove(url) != nil { try? fileManager.removeItem(at: url) }
                continuation.resume()
            }
        }
    }

    public func diagnostics() async -> (sessionLoadCount: Int, generatedFileCount: Int) {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in continuation.resume(returning: (sessionLoadCount, generatedAudioURLs.count)) }
        }
    }

    private func loadRuntimeIfNeeded() throws -> Runtime {
        if let runtime { return runtime }
        let loaded = try Runtime(assets: assets, threads: threads)
        runtime = loaded
        sessionLoadCount += 1
        return loaded
    }
}
