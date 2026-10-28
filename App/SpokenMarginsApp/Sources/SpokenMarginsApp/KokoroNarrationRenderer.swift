import Foundation
import KokoroPipeline
import SessionKit
import SessionKitSpeechFrontEnd
import SessionKitSupertonic

/// The downloaded Kokoro-82M voice (#2705), on Core ML through the Apache-2.0 port `mattmireles/kokoro-coreml`'s
/// `KokoroPipeline`. Shaped like `KittenNarrationRenderer`: one serial queue, the pipeline loaded on first use and
/// kept until `unload()`, inference paced by the shared `OnDeviceVoiceGovernor` in the background (#1679), and the
/// audio written to a WAV file the renderer owns.
///
/// Text is cut by `KokoroBucketPlanner` so every inference fits the 3 s or 7 s bucket (the only ones downloaded,
/// all on the Neural Engine and CPU, never the GPU), and the pieces are joined at their seams by
/// `KokoroSeamJoiner`. A piece whose audio fills the 7 s bucket may have been cut off by the pipeline, so it is
/// halved (by words, or by characters for one long word) and rendered again. Pronunciations come from the bundled Kitten front end (`KokoroFrontEnd`).
///
/// Wiring (not done here): construct it with the voice's installed folder
/// (`VoiceModelInstaller.installedFolder(voiceId: KokoroVoice.catalogId, version:)`), the bundled Kitten folder and
/// the chosen voice; select it when the listener picks a Kokoro voice; file its audio under
/// `KokoroRenderSignature.make(voice:entry:)`.
final class KokoroNarrationRenderer: @unchecked Sendable {
    static let engine = KokoroRenderSignature.engine
    static let sampleRate = KokoroVoice.sampleRate
    /// How many times a piece the 7 s bucket may have cut off is halved before it is kept as it is.
    static let maxResplits = 3
    /// What `warmUp()` renders: one text for the 3 s bucket (about 12 characters at 14 a second) and one for the 7 s
    /// bucket (about 75), so each bucket's models are specialised for the Neural Engine before the first Play (#2856).
    static let warmUpTexts = ["Hello there.", "This is a short sentence that warms the longer model before you press play."]

    enum RenderError: Error, LocalizedError, Equatable {
        case missingFile(String)
        case unknownVoice(String)
        case emptyText
        case emptyAudio
        case unsafeAudio(String)

        var errorDescription: String? {
            switch self {
            case .missingFile(let name): "Kokoro's file is missing: \(name). Download the voice again in Settings › Voices."
            case .unknownVoice(let voice): "Kokoro has no voice named \(voice)."
            case .emptyText: "The text to speak is empty."
            case .emptyAudio: "Kokoro generated no playable audio."
            case .unsafeAudio(let reason): "Kokoro generated invalid audio: \(reason)."
            }
        }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    /// How many loads (a warm-up, or the first render) are queued or running; the player reads it from any thread.
    private final class LoadingCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var isLoading: Bool { lock.withLock { count > 0 } }
        func begin() { lock.withLock { count += 1 } }
        func end() { lock.withLock { count -= 1 } }
    }

    private final class Runtime {
        let pipeline: KokoroPipeline
        let frontEnd: KokoroFrontEnd
        let styleRows: [Float]

        init(voiceFolder: URL, kittenAssets: KittenAssetLocation, voice: String) throws {
            let fileManager = FileManager.default
            func required(_ path: String) throws -> URL {
                let url = voiceFolder.appending(path: path)
                guard fileManager.fileExists(atPath: url.path) else { throw RenderError.missingFile(path) }
                return url
            }
            struct HNSF: Decodable {
                let linear_weights: [Float]
                let linear_bias: Float
            }
            let hnsf = try JSONDecoder().decode(HNSF.self, from: Data(contentsOf: required(KokoroVoice.hnsfWeightsPath)))
            pipeline = try KokoroPipeline(
                modelsDirectory: try required(KokoroVoice.modelsFolderName),
                buckets: KokoroVoice.bucketSeconds,
                linearWeights: hnsf.linear_weights,
                linearBias: hnsf.linear_bias,
                compiledModelCache: voiceFolder.appending(path: KokoroVoice.compiledFolderName, directoryHint: .isDirectory)
            )
            let kitten = try KittenFrontEnd(lexiconURL: kittenAssets.lexiconURL, g2pWeightsURL: kittenAssets.g2pWeightsURL,
                                            g2pManifestURL: kittenAssets.g2pManifestURL)
            // misaki's gold and silver dictionaries first (prepared from the download), Kitten's front end only
            // for a word in neither (#2705).
            let lexicon = try MisakiLexicon(contentsOf: required(KokoroVoice.preparedLexiconPath))
            frontEnd = try KokoroFrontEnd(vocabJSON: Data(contentsOf: required(KokoroVoice.vocabPath)), lexicon: lexicon, fallback: kitten)
            let voiceData = try Data(contentsOf: required(KokoroVoice.voicePath(voice)))
            let width = PipelineConstants.voiceEmbeddingDim
            guard !voiceData.isEmpty, voiceData.count % (width * MemoryLayout<Float>.size) == 0 else {
                throw RenderError.missingFile(KokoroVoice.voicePath(voice))
            }
            var rows = [Float](repeating: 0, count: voiceData.count / MemoryLayout<Float>.size)
            rows.withUnsafeMutableBytes { _ = voiceData.copyBytes(to: $0) }
            styleRows = rows
        }

        func style(row: Int) -> [Float] {
            let width = PipelineConstants.voiceEmbeddingDim
            let index = max(0, min(styleRows.count / width - 1, row)) * width
            return Array(styleRows[index..<(index + width)])
        }
    }

    let voice: String
    private let voiceFolder: URL
    private let kittenAssets: KittenAssetLocation
    private let outputDirectory: URL
    private let fileManager: FileManager
    /// Paces inference in the background, for every on-device voice alike (#1679).
    let governor: OnDeviceVoiceGovernor
    private let renderQueue = DispatchQueue(label: "com.spokenmargins.kokoro.render", qos: .userInitiated)
    private var runtime: Runtime?
    /// Whether this runtime has run one inference yet. The first one makes Core ML specialise the models for the
    /// Neural Engine, which is the slow part of a voice's first Play (#2856). Read and written on `renderQueue` only.
    private var hasRunWarmInference = false
    private let loadingCount = LoadingCount()
    /// Receives `voice.load` for the diagnostics export; set by whoever builds the renderer.
    private let events: @Sendable (String, [String: String]) -> Void
    private var sessionLoadCount = 0
    private var generatedAudioURLs: Set<URL> = []
    /// When the next inference may start, from the last one's cost (#1679). Read and written on `renderQueue` only.
    private var nextInferenceNotBefore: TimeInterval?

    /// `voiceFolder` is the installed `kokoro-82m` folder (it holds `coreml/`, `compiled/`, `voices/`, `runtime/`).
    init(
        voiceFolder: URL, kittenAssets: KittenAssetLocation, voice: String = KokoroVoice.defaultVoice,
        outputDirectory: URL, governor: OnDeviceVoiceGovernor, fileManager: FileManager = .default,
        events: @escaping @Sendable (String, [String: String]) -> Void = { _, _ in }
    ) throws {
        guard KokoroVoice.voices.contains(voice) else { throw RenderError.unknownVoice(voice) }
        try kittenAssets.validate(fileManager: fileManager)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        self.voice = voice
        self.voiceFolder = voiceFolder
        self.kittenAssets = kittenAssets
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
        self.governor = governor
        self.events = events
    }

    /// Live narration: paced only while the app is in the background.
    func render(text: String) async throws -> SupertonicNarrationResult {
        try await render(text: text, speed: 1, pacing: .whenAppBackgrounded)
    }

    func render(text: String, speed: Float, pacing: OnDeviceRenderPacing) async throws -> SupertonicNarrationResult {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw RenderError.emptyText }
        try Task.checkCancellation()
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                renderQueue.async { [self] in
                    autoreleasepool {
                        do {
                            continuation.resume(returning: try renderOnQueue(spoken, speed: speed, pacing: pacing, cancellation: cancellation))
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

    private func renderOnQueue(
        _ text: String, speed: Float, pacing: OnDeviceRenderPacing, cancellation: CancellationFlag, trigger: String = "render"
    ) throws -> SupertonicNarrationResult {
        let startedAt = Date()
        // Until this runtime has finished one render, the pipeline load and the Neural Engine specialisation inside its
        // first inferences (both buckets) are all loading, so the player keeps waiting through them (#2856).
        let cold = !hasRunWarmInference
        if cold { loadingCount.begin() }
        defer { if cold { loadingCount.end() } }
        // Loading the pipeline is paid once and isn't counted as inference.
        let runtime = try loadRuntimeIfNeeded(trigger: trigger)
        let planner = KokoroBucketPlanner(speed: Double(speed))
        var queue = planner.pieces(for: text).map { (piece: $0, resplits: 0) }
        var segments: [[Float]] = []
        var seams: [KokoroBucketPlanner.Seam] = []
        while !queue.isEmpty {
            let (piece, resplits) = queue.removeFirst()
            guard !cancellation.isCancelled else { throw CancellationError() }
            // The rest the last inference earned, waited out under this render's own pacing and cancellation.
            if let notBefore = nextInferenceNotBefore {
                try governor.waitForNextInference(notBefore: notBefore, pacing: pacing) {
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    return true
                }
                nextInferenceNotBefore = nil
            }
            guard let input = runtime.frontEnd.input(for: piece.text, paddedLength: KokoroVoice.durationTokenLength) else {
                // Too many phonemes for the duration model: skip a piece that says nothing, else cut it, by words or,
                // for one long word, by characters. Speech is never dropped without a word: a piece that can't be
                // cut fails the render, and the player's stand-in reads the passage (#2762 audit).
                guard runtime.frontEnd.phonemes(for: piece.text).contains(where: { !$0.isWhitespace && !$0.isPunctuation }) else {
                    continue
                }
                guard let pieces = planner.split(piece) else { throw RenderError.unsafeAudio("unsplittable_piece") }
                queue.insert(contentsOf: pieces.map { ($0, resplits + 1) }, at: 0)
                continue
            }
            let (result, cost) = try governor.measureInference {
                try runtime.pipeline.synthesize(inputIds: input.inputIds, attentionMask: input.attentionMask,
                                                refS: runtime.style(row: input.styleRow), speed: speed)
            }
            nextInferenceNotBefore = governor.nextInference(after: cost, pacing: pacing)
            if KokoroBucketPlanner.mayHaveOverflowed(audioSeconds: result.audioDurationSeconds, bucketSeconds: result.bucketSeconds),
               resplits < Self.maxResplits, let halves = planner.split(piece) {
                queue.insert(contentsOf: halves.map { ($0, resplits + 1) }, at: 0)
                continue
            }
            segments.append(result.audio)
            seams.append(piece.seamAfter)
        }
        hasRunWarmInference = true
        let joined = KokoroSeamJoiner.join(segments: segments, seams: seams, sampleRate: Self.sampleRate)
        guard !joined.isEmpty else { throw RenderError.emptyAudio }
        guard joined.allSatisfy(\.isFinite) else { throw RenderError.unsafeAudio("non_finite_samples") }
        guard joined.lazy.map({ abs($0) }).max() ?? 0 > 0.000_001 else { throw RenderError.unsafeAudio("silent_output") }
        let kept = SpeechSilenceTrim.speechRange(in: joined, sampleRate: Self.sampleRate).map { Array(joined[$0]) } ?? joined
        let trimmedSilence = TimeInterval(joined.count - kept.count) / TimeInterval(Self.sampleRate)
        let audioURL = outputDirectory.appending(path: "kokoro-\(UUID().uuidString).wav")
        try KokoroWaveFile.data(samples: kept, sampleRate: Self.sampleRate).write(to: audioURL, options: .atomic)
        generatedAudioURLs.insert(audioURL)
        return SupertonicNarrationResult(
            audioURL: audioURL,
            duration: TimeInterval(kept.count) / TimeInterval(Self.sampleRate),
            sampleRate: Self.sampleRate,
            renderDuration: Date().timeIntervalSince(startedAt),
            sessionLoadCount: sessionLoadCount,
            engine: Self.engine,
            trimmedSilence: trimmedSilence
        )
    }

    /// True while the model is loading or being warmed (#2856): the player waits longer than for a slow render.
    var isLoadingModel: Bool { loadingCount.isLoading }

    /// Loads the pipeline and runs one short render, so the Neural Engine specialisation happens now and not inside
    /// the listener's first Play (#2856). Never throws: a failure is logged as `voice.load` and the first Play reports
    /// it again. The sample audio is deleted at once.
    func warmUp() async {
        loadingCount.begin()
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                defer {
                    loadingCount.end()
                    continuation.resume()
                }
                autoreleasepool {
                    guard !hasRunWarmInference else { return }
                    let started = Date()
                    do {
                        for text in Self.warmUpTexts {
                            let result = try renderOnQueue(text, speed: 1, pacing: .whenAppBackgrounded, cancellation: CancellationFlag(), trigger: "warm")
                            nextInferenceNotBefore = nil // a warm-up's cost must not hold back the next text or a real render
                            try? fileManager.removeItem(at: result.audioURL)
                            generatedAudioURLs.remove(result.audioURL)
                        }
                        events("voice.warm", ["voice": KokoroVoice.catalogId, "ms": Self.milliseconds(since: started), "result": "ok"])
                    } catch {
                        events("voice.warm", ["voice": KokoroVoice.catalogId, "ms": Self.milliseconds(since: started), "result": Self.describe(error)])
                    }
                }
            }
        }
    }

    private static func milliseconds(since start: Date) -> String { String(Int(Date().timeIntervalSince(start) * 1000)) }

    /// The error's type and, for Kokoro's own, its case, so a failed export names it (a bare type said only "RenderError").
    static func describe(_ error: Error) -> String {
        let text = String(describing: error)
        return "failed:\(type(of: error)):\(text.prefix(120))"
    }

    /// Drops the pipeline and the front end, and by default the audio this renderer wrote.
    func unload(removingGeneratedAudio: Bool = true) async {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                runtime = nil
                hasRunWarmInference = false
                if removingGeneratedAudio {
                    for url in generatedAudioURLs { try? fileManager.removeItem(at: url) }
                    generatedAudioURLs.removeAll()
                }
                continuation.resume()
            }
        }
    }

    /// Deletes `url` only if this renderer wrote it (callers also pass files other renderers own).
    func discardGeneratedAudio(at url: URL) async {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                if generatedAudioURLs.remove(url) != nil { try? fileManager.removeItem(at: url) }
                continuation.resume()
            }
        }
    }

    func diagnostics() async -> (sessionLoadCount: Int, generatedFileCount: Int) {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in continuation.resume(returning: (sessionLoadCount, generatedAudioURLs.count)) }
        }
    }

    private func loadRuntimeIfNeeded(trigger: String) throws -> Runtime {
        if let runtime { return runtime }
        loadingCount.begin()
        defer { loadingCount.end() }
        let started = Date()
        let loaded: Runtime
        do {
            loaded = try Runtime(voiceFolder: voiceFolder, kittenAssets: kittenAssets, voice: voice)
        } catch {
            events("voice.load", ["voice": KokoroVoice.catalogId, "trigger": trigger, "ms": Self.milliseconds(since: started), "result": Self.describe(error)])
            throw error
        }
        runtime = loaded
        sessionLoadCount += 1
        events("voice.load", ["voice": KokoroVoice.catalogId, "trigger": trigger, "ms": Self.milliseconds(since: started), "result": "ok"])
        return loaded
    }
}

/// The chosen-voice seam the playback client renders through. Kokoro has one voice per renderer, so the
/// Supertonic voice and step count are ignored; `speed` is passed to the model.
extension KokoroNarrationRenderer: SupertonicRendering {
    /// Kokoro's own name, not the protocol's Supertonic default, so used directly its chunks are not filed as stand-ins (#2700).
    var engine: String { Self.engine }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        try await render(text: text, speed: speed, pacing: .whenAppBackgrounded)
    }
}
