import Foundation

/// `bundle.json` of the ONNX export: the sizes the networks expect and, for each network that
/// carries state between calls, the list of state tensors in the order the network takes them.
struct PocketBundle: Decodable, Sendable {
    struct StateEntry: Decodable, Sendable {
        var dtype: String
        var fill: String
        var index: Int
        var inputName: String
        var outputName: String
        var key: String
        var module: String
        var shape: [Int]

        enum CodingKeys: String, CodingKey {
            case dtype, fill, index, key, module, shape
            case inputName = "input_name"
            case outputName = "output_name"
        }

        var tensorDType: PocketTensor.DType? { PocketTensor.DType(rawValue: dtype) }
        var tensorFill: PocketTensor.Fill { PocketTensor.Fill(rawValue: fill) ?? .zeros }
    }

    var bundleName: String
    var sampleRate: Int
    var frameRate: Double
    var samplesPerFrame: Int
    var latentDim: Int
    var conditioningDim: Int
    var maxTokensPerChunk: Int
    var padWithSpacesForShortInputs: Bool
    var removeSemicolons: Bool
    var modelRecommendedFramesAfterEOS: Int?
    var flowStates: [StateEntry]
    var mimiStates: [StateEntry]

    enum CodingKeys: String, CodingKey {
        case bundleName = "bundle_name"
        case sampleRate = "sample_rate"
        case frameRate = "frame_rate"
        case samplesPerFrame = "samples_per_frame"
        case latentDim = "latent_dim"
        case conditioningDim = "conditioning_dim"
        case maxTokensPerChunk = "max_token_per_chunk"
        case padWithSpacesForShortInputs = "pad_with_spaces_for_short_inputs"
        case removeSemicolons = "remove_semicolons"
        case modelRecommendedFramesAfterEOS = "model_recommended_frames_after_eos"
        case flowStates = "flow_lm_state_manifest"
        case mimiStates = "mimi_state_manifest"
    }

    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(PocketBundle.self, from: Data(contentsOf: url))
        // The runtime was written against the one 6-layer English bundle and refuses an export
        // whose pieces it doesn't know how to prepare.
        guard !padWithSpacesForShortInputs else { throw PocketNarrationError.unsupportedBundle("short-input padding") }
        guard !removeSemicolons else { throw PocketNarrationError.unsupportedBundle("semicolon removal") }
        guard modelRecommendedFramesAfterEOS == nil else {
            throw PocketNarrationError.unsupportedBundle("a fixed number of frames after the end")
        }
    }
}
