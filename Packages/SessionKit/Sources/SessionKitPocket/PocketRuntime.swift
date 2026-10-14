import Foundation
import OnnxRuntimeBindings

/// Where Pocket TTS's files are: the folder `research/C2/pocket/fetch_weights.sh` fills.
public struct PocketAssetLocation: Equatable, Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static let modelFiles = [
        "bundle.json", "tokenizer.model", "text_conditioner.onnx", "flow_lm_main_int8.onnx",
        "flow_lm_flow_int8.onnx", "mimi_decoder_int8.onnx"
    ]

    func url(_ name: String) -> URL { rootURL.appending(path: name) }

    func voiceURL(_ voice: PocketVoiceID) -> URL { url("\(voice.rawValue).safetensors") }

    public func validate(voice: PocketVoiceID = .alba, fileManager: FileManager = .default) throws {
        for name in Self.modelFiles + ["\(voice.rawValue).safetensors"] {
            guard fileManager.fileExists(atPath: url(name).path) else {
                throw PocketNarrationError.missingAsset(name)
            }
        }
    }
}

/// The voices this slice can speak. Alba's voice data is CC BY 4.0; the voices from the Expresso
/// and EARS sets (cosette, jean) are non-commercial and stay out.
public enum PocketVoiceID: String, CaseIterable, Sendable {
    case alba
}

public enum PocketNarrationError: Error, LocalizedError, Equatable {
    case missingAsset(String)
    case unsupportedBundle(String)
    case emptyText
    case modelOutput(String)
    case emptyAudio
    case unsafeAudio(String)

    public var errorDescription: String? {
        switch self {
        case .missingAsset(let name): return "Pocket TTS file is missing: \(name)."
        case .unsupportedBundle(let what): return "Pocket TTS export is not one this build reads: \(what)."
        case .emptyText: return "The text to speak is empty."
        case .modelOutput(let what): return "Pocket TTS returned something unexpected: \(what)."
        case .emptyAudio: return "Pocket TTS generated no playable audio."
        case .unsafeAudio(let reason): return "Pocket TTS generated invalid audio: \(reason)."
        }
    }
}

/// A source of the Gaussian noise that starts each frame. Seeded in tests so a render repeats.
struct PocketNoise {
    private var generator: SplitMix64

    init(seed: UInt64?) {
        generator = SplitMix64(seed: seed ?? UInt64.random(in: .min ... .max))
    }

    /// `count` draws from a normal distribution with mean 0 and standard deviation `deviation`.
    mutating func normals(count: Int, deviation: Float) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(count)
        while values.count < count {
            // Box-Muller from two uniform draws in (0, 1].
            let u1 = Float.random(in: Float.leastNormalMagnitude...1, using: &generator)
            let u2 = Float.random(in: 0..<1, using: &generator)
            let radius = (-2 * log(u1)).squareRoot()
            values.append(deviation * radius * cos(2 * .pi * u2))
            if values.count < count { values.append(deviation * radius * sin(2 * .pi * u2)) }
        }
        return values
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The five networks and the state they pass along. Not thread-safe: the renderer calls it from
/// one serial queue.
final class PocketRuntime: @unchecked Sendable {
    /// The model's temperature: the noise that starts each frame has this variance.
    static let temperature: Float = 0.7
    /// Frames the model makes per second of speech, and so the cap on a chunk is set from it.
    static let maxSecondsPerToken: Float = 1 / 3
    static let paddingSeconds: Float = 2
    /// An end-of-speech score above this means the model has finished the text.
    static let endLogitThreshold: Float = -4
    /// The decoder takes this many frames at a time.
    static let decodeFrames = 12

    let bundle: PocketBundle
    let preparation: PocketTextPreparation
    private let environment: ORTEnv
    private let textConditioner: ORTSession
    private let flowMain: ORTSession
    private let flowFlow: ORTSession
    private let mimiDecoder: ORTSession
    private let trueValue: ORTValue
    private let voiceState: [ORTValue]
    private let flowSteps: Int
    private let emptySequence: ORTValue
    private let emptyText: ORTValue

    init(assets: PocketAssetLocation, voice: PocketVoiceID, threads: Int, flowSteps: Int = 1) throws {
        try assets.validate(voice: voice)
        let bundle = try PocketBundle(contentsOf: assets.url("bundle.json"))
        self.bundle = bundle
        self.flowSteps = max(1, flowSteps)
        let tokenizer = try PocketSentencePiece(contentsOf: assets.url("tokenizer.model"))
        preparation = PocketTextPreparation(tokenizer: tokenizer, maxTokensPerChunk: bundle.maxTokensPerChunk)

        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(max(1, threads)))
        textConditioner = try ORTSession(env: environment, modelPath: assets.url("text_conditioner.onnx").path, sessionOptions: options)
        flowMain = try ORTSession(env: environment, modelPath: assets.url("flow_lm_main_int8.onnx").path, sessionOptions: options)
        flowFlow = try ORTSession(env: environment, modelPath: assets.url("flow_lm_flow_int8.onnx").path, sessionOptions: options)
        mimiDecoder = try ORTSession(env: environment, modelPath: assets.url("mimi_decoder_int8.onnx").path, sessionOptions: options)

        trueValue = try Self.makeTrueValue(environment: environment, scratch: assets.rootURL)
        emptySequence = try Self.value(PocketTensor.filled(.float32, shape: [1, 0, bundle.latentDim], fill: .zeros), trueValue: trueValue)
        emptyText = try Self.value(PocketTensor.filled(.float32, shape: [1, 0, bundle.conditioningDim], fill: .zeros), trueValue: trueValue)

        let saved = try PocketSafetensors(contentsOf: assets.voiceURL(voice))
        voiceState = try Self.initialState(bundle.flowStates, saved: saved, trueValue: trueValue)
    }

    // MARK: Rendering

    /// Speech for `text` as 24 kHz samples. Throws `CancellationError` when `isCancelled` turns true,
    /// which it is asked between frames.
    func render(text: String, noise: inout PocketNoise, isCancelled: () -> Bool) throws -> [Float] {
        var samples: [Float] = []
        for chunk in preparation.chunks(for: text) {
            if isCancelled() { throw CancellationError() }
            samples.append(contentsOf: try render(chunk: chunk, noise: &noise, isCancelled: isCancelled))
        }
        return samples
    }

    private func render(chunk: PocketTextPreparation.Chunk, noise: inout PocketNoise, isCancelled: () -> Bool) throws -> [Float] {
        var state = voiceState
        let flowNames = bundle.flowStates.sorted { $0.index < $1.index }
        let flowOutputNames = Set(["conditioning", "eos_logit"] + flowNames.map(\.outputName))

        let ids = chunk.tokenIDs.map(Int64.init)
        let idsValue = try Self.value(PocketTensor(dtype: .int64, shape: [1, ids.count], data: ids.withUnsafeBytes { Data($0) }), trueValue: trueValue)
        let embeddings = try textConditioner.run(withInputs: ["token_ids": idsValue], outputNames: ["embeddings"], runOptions: nil)["embeddings"]
        guard let embeddings else { throw PocketNarrationError.modelOutput("text embeddings") }

        // Feed the text in, keeping only the state it leaves behind.
        func runMain(sequence: ORTValue, text: ORTValue) throws -> [String: ORTValue] {
            var inputs: [String: ORTValue] = ["sequence": sequence, "text_embeddings": text]
            for (entry, value) in zip(flowNames, state) { inputs[entry.inputName] = value }
            let outputs = try flowMain.run(withInputs: inputs, outputNames: flowOutputNames, runOptions: nil)
            state = try flowNames.map { entry in
                guard let value = outputs[entry.outputName] else { throw PocketNarrationError.modelOutput(entry.outputName) }
                return value
            }
            return outputs
        }
        _ = try runMain(sequence: emptySequence, text: embeddings)

        let latentDim = bundle.latentDim
        var current = try Self.value(PocketTensor.filled(.float32, shape: [1, 1, latentDim], fill: .nan), trueValue: trueValue)
        let frameLimit = Int(ceil((Float(ids.count) * Self.maxSecondsPerToken + Self.paddingSeconds) * Float(bundle.frameRate)))
        let deviation = Self.temperature.squareRoot()
        let stepSize = 1 / Float(flowSteps)

        var mimiState = try Self.initialState(bundle.mimiStates, saved: nil, trueValue: trueValue)
        var pending: [Float] = []
        var pendingFrames = 0
        var samples: [Float] = []
        func decodePending() throws {
            guard pendingFrames > 0 else { return }
            let latent = try Self.value(
                PocketTensor(dtype: .float32, shape: [1, pendingFrames, latentDim], data: pending.withUnsafeBytes { Data($0) }),
                trueValue: trueValue
            )
            var inputs: [String: ORTValue] = ["latent": latent]
            let names = bundle.mimiStates.sorted { $0.index < $1.index }
            for (entry, value) in zip(names, mimiState) { inputs[entry.inputName] = value }
            let outputs = try mimiDecoder.run(
                withInputs: inputs, outputNames: Set(["audio_frame"] + names.map(\.outputName)), runOptions: nil
            )
            guard let audio = outputs["audio_frame"] else { throw PocketNarrationError.modelOutput("audio_frame") }
            samples.append(contentsOf: try Self.floats(audio))
            mimiState = try names.map { entry in
                guard let value = outputs[entry.outputName] else { throw PocketNarrationError.modelOutput(entry.outputName) }
                return value
            }
            pending.removeAll(keepingCapacity: true)
            pendingFrames = 0
        }

        var endStep: Int?
        for step in 0..<frameLimit {
            if isCancelled() { throw CancellationError() }
            try autoreleasepool {
                let outputs = try runMain(sequence: current, text: emptyText)
                guard let conditioning = outputs["conditioning"], let endLogit = outputs["eos_logit"] else {
                    throw PocketNarrationError.modelOutput("conditioning")
                }
                if endStep == nil, try Self.floats(endLogit).first.map({ $0 > Self.endLogitThreshold }) == true {
                    endStep = step
                }
                if let endStep, step >= endStep + chunk.framesAfterEnd { return }

                var x = noise.normals(count: latentDim, deviation: deviation)
                for flowStep in 0..<flowSteps {
                    let from = Float(flowStep) / Float(flowSteps)
                    let inputs: [String: ORTValue] = [
                        "c": conditioning,
                        "s": try Self.value(Self.scalar(from), trueValue: trueValue),
                        "t": try Self.value(Self.scalar(from + stepSize), trueValue: trueValue),
                        "x": try Self.value(Self.vector(x), trueValue: trueValue)
                    ]
                    let flow = try flowFlow.run(withInputs: inputs, outputNames: ["flow_dir"], runOptions: nil)
                    guard let direction = flow["flow_dir"] else { throw PocketNarrationError.modelOutput("flow_dir") }
                    let delta = try Self.floats(direction)
                    guard delta.count == x.count else { throw PocketNarrationError.modelOutput("flow_dir size") }
                    for index in x.indices { x[index] += delta[index] * stepSize }
                }
                pending.append(contentsOf: x)
                pendingFrames += 1
                current = try Self.value(Self.vector(x, shape: [1, 1, latentDim]), trueValue: trueValue)
                if pendingFrames == Self.decodeFrames { try decodePending() }
            }
            if let endStep, step >= endStep + chunk.framesAfterEnd { break }
        }
        try decodePending()
        return samples
    }

    // MARK: Values

    private static func scalar(_ value: Float) -> PocketTensor {
        PocketTensor(dtype: .float32, shape: [1, 1], data: [value].withUnsafeBytes { Data($0) })
    }

    private static func vector(_ values: [Float], shape: [Int]? = nil) -> PocketTensor {
        PocketTensor(dtype: .float32, shape: shape ?? [1, values.count], data: values.withUnsafeBytes { Data($0) })
    }

    static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func value(_ tensor: PocketTensor, trueValue: ORTValue) throws -> ORTValue {
        let shape = tensor.shape.map { NSNumber(value: $0) }
        switch tensor.dtype {
        case .float32:
            return try ORTValue(tensorData: NSMutableData(data: tensor.data), elementType: .float, shape: shape)
        case .int64:
            return try ORTValue(tensorData: NSMutableData(data: tensor.data), elementType: .int64, shape: shape)
        case .bool:
            // The Swift bindings can't make boolean tensors; the one the decoder asks for is "true".
            guard tensor.shape == [1], tensor.data == Data([1]) else {
                throw PocketNarrationError.unsupportedBundle("a boolean state other than [true]")
            }
            return trueValue
        }
    }

    private static func initialState(_ entries: [PocketBundle.StateEntry], saved: PocketSafetensors?, trueValue: ORTValue) throws -> [ORTValue] {
        try entries.sorted { $0.index < $1.index }.map { entry in
            guard let dtype = entry.tensorDType else { throw PocketNarrationError.unsupportedBundle("state type \(entry.dtype)") }
            var tensor = PocketTensor.filled(dtype, shape: entry.shape, fill: entry.tensorFill)
            if let saved {
                let module = saved.moduleState(entry.module)
                if let stored = module[entry.key] {
                    tensor = stored.placed(intoShape: entry.shape, fill: entry.tensorFill)
                } else if entry.key == "step", let offset = module["offset"], module["end_offset"] == nil {
                    tensor = offset.placed(intoShape: entry.shape, fill: entry.tensorFill)
                }
            }
            return try value(tensor, trueValue: trueValue)
        }
    }

    // MARK: The boolean constant

    /// A boolean `true` tensor, made by running a tiny model that holds one. The bindings can't
    /// build a boolean tensor from bytes, and the decoder's streaming state wants a few.
    private static func makeTrueValue(environment: ORTEnv, scratch: URL) throws -> ORTValue {
        let modelURL = scratch.appending(path: ".bool-true-\(UUID().uuidString).onnx")
        try Data(PocketBoolModel.trueConstantModel).write(to: modelURL)
        defer { try? FileManager.default.removeItem(at: modelURL) }
        let session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: nil)
        guard let value = try session.run(withInputs: [:], outputNames: ["flag"], runOptions: nil)["flag"] else {
            throw PocketNarrationError.modelOutput("boolean constant")
        }
        return value
    }
}

/// An ONNX model with no inputs and one output, a boolean `[true]`, written out byte by byte.
enum PocketBoolModel {
    static let trueConstantModel: [UInt8] = {
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 0x7F)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }
        func number(_ field: UInt64, _ value: UInt64) -> [UInt8] { varint(field << 3) + varint(value) }
        func bytes(_ field: UInt64, _ payload: [UInt8]) -> [UInt8] { varint(field << 3 | 2) + varint(UInt64(payload.count)) + payload }
        func string(_ field: UInt64, _ text: String) -> [UInt8] { bytes(field, Array(text.utf8)) }

        let boolType: UInt64 = 9
        // TensorProto { dims: [1], data_type: BOOL, raw_data: [1] }
        let tensor = number(1, 1) + number(2, boolType) + bytes(9, [1])
        // AttributeProto { name: "value", t: tensor, type: TENSOR }
        let attribute = string(1, "value") + bytes(5, tensor) + number(20, 4)
        // NodeProto { output: ["flag"], op_type: "Constant", attribute }
        let node = string(2, "flag") + string(4, "Constant") + bytes(5, attribute)
        // ValueInfoProto { name: "flag", type: tensor_type { elem_type: BOOL, shape: [1] } }
        let shape = bytes(1, number(1, 1))
        let tensorType = bytes(1, number(1, boolType) + bytes(2, shape))
        let valueInfo = string(1, "flag") + bytes(2, tensorType)
        let graph = bytes(1, node) + string(2, "bool_true") + bytes(12, valueInfo)
        // ModelProto { ir_version: 8, opset_import: [{version: 13}], graph }
        return number(1, 8) + bytes(8, number(2, 13)) + bytes(7, graph)
    }()
}
