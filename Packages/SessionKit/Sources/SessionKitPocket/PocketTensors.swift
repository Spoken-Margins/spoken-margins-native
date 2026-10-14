import Foundation

/// A plain tensor held in memory before it becomes an onnxruntime value.
struct PocketTensor: Equatable, Sendable {
    enum DType: String, Sendable {
        case float32
        case int64
        case bool
    }

    var dtype: DType
    var shape: [Int]
    var data: Data

    var elementCount: Int { shape.reduce(1, *) }

    static func filled(_ dtype: DType, shape: [Int], fill: Fill) -> PocketTensor {
        let count = shape.reduce(1, *)
        switch dtype {
        case .float32:
            let value: Float = fill == .nan ? .nan : (fill == .ones ? 1 : 0)
            let values = [Float](repeating: value, count: count)
            return PocketTensor(dtype: .float32, shape: shape, data: values.withUnsafeBytes { Data($0) })
        case .int64:
            let value: Int64 = fill == .ones ? 1 : 0
            let values = [Int64](repeating: value, count: count)
            return PocketTensor(dtype: .int64, shape: shape, data: values.withUnsafeBytes { Data($0) })
        case .bool:
            return PocketTensor(
                dtype: .bool, shape: shape,
                data: Data(repeating: fill == .ones ? 1 : 0, count: count)
            )
        }
    }

    enum Fill: String, Sendable {
        case nan
        case ones
        case zeros
        case empty
    }
}

/// Reads a `.safetensors` file: a length, a JSON table of tensors, then their raw bytes.
/// Only the element types Pocket TTS's voice states use are read.
struct PocketSafetensors: Sendable {
    enum ReadError: Error, Equatable {
        case malformed(String)
        case unsupportedType(String)
    }

    private(set) var tensors: [String: PocketTensor]

    init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        guard data.count >= 8 else { throw ReadError.malformed("shorter than its length field") }
        var headerLength: UInt64 = 0
        for (offset, byte) in data.prefix(8).enumerated() { headerLength |= UInt64(byte) << (8 * UInt64(offset)) }
        let bodyStart = 8 + Int(clamping: headerLength)
        guard headerLength < 100_000_000, bodyStart <= data.count else {
            throw ReadError.malformed("header runs past the end")
        }
        let headerData = data[data.startIndex + 8 ..< data.startIndex + bodyStart]
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw ReadError.malformed("header is not an object")
        }

        var tensors: [String: PocketTensor] = [:]
        for (name, entry) in header where name != "__metadata__" {
            guard let entry = entry as? [String: Any],
                  let dtypeName = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [Int],
                  let offsets = entry["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[0] <= offsets[1], bodyStart + offsets[1] <= data.count else {
                throw ReadError.malformed("tensor \(name)")
            }
            let dtype: PocketTensor.DType
            let width: Int
            switch dtypeName {
            case "F32": (dtype, width) = (.float32, 4)
            case "I64": (dtype, width) = (.int64, 8)
            case "BOOL": (dtype, width) = (.bool, 1)
            default: throw ReadError.unsupportedType(dtypeName)
            }
            let tensor = PocketTensor(
                dtype: dtype, shape: shape,
                data: Data(data[data.startIndex + bodyStart + offsets[0] ..< data.startIndex + bodyStart + offsets[1]])
            )
            guard tensor.data.count == tensor.elementCount * width else {
                throw ReadError.malformed("tensor \(name) holds \(tensor.data.count) bytes for shape \(shape)")
            }
            tensors[name] = tensor
        }
        self.tensors = tensors
    }

    /// The tensors of one module, keyed by name: `transformer.layers.0.self_attn/cache` is the
    /// `cache` of module `transformer.layers.0.self_attn`.
    func moduleState(_ module: String) -> [String: PocketTensor] {
        var result: [String: PocketTensor] = [:]
        let prefix = module + "/"
        for (name, tensor) in tensors where name.hasPrefix(prefix) {
            result[String(name.dropFirst(prefix.count))] = tensor
        }
        return result
    }
}

extension PocketTensor {
    /// Places this saved tensor into a tensor of `shape` filled with `fill`, as the voice states
    /// need: the saved key/value cache holds 126 steps of a cache sized for 1,000, and the rest
    /// stays NaN. Row-major, so it copies the overlapping block from the corner.
    func placed(intoShape target: [Int], fill: Fill) -> PocketTensor {
        if shape == target { return self }
        let count = target.reduce(1, *)
        let width = dtype == .float32 ? 4 : (dtype == .int64 ? 8 : 1)
        if elementCount == count { return PocketTensor(dtype: dtype, shape: target, data: data) }
        var result = PocketTensor.filled(dtype, shape: target, fill: fill)
        guard shape.count == target.count, count > 0, elementCount > 0 else { return result }

        let overlap = zip(shape, target).map(min)
        let rank = shape.count
        func strides(_ shape: [Int]) -> [Int] {
            var strides = [Int](repeating: 1, count: shape.count)
            for axis in stride(from: shape.count - 2, through: 0, by: -1) {
                strides[axis] = strides[axis + 1] * shape[axis + 1]
            }
            return strides
        }
        let sourceStrides = strides(shape)
        let targetStrides = strides(target)
        // The last axis is contiguous in both, so each row copies in one go.
        let rowBytes = overlap[rank - 1] * width
        var index = [Int](repeating: 0, count: rank)
        result.data.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                while true {
                    var from = 0
                    var to = 0
                    for axis in 0..<rank {
                        from += index[axis] * sourceStrides[axis]
                        to += index[axis] * targetStrides[axis]
                    }
                    memcpy(destination.baseAddress! + to * width, source.baseAddress! + from * width, rowBytes)
                    var axis = rank - 2
                    while axis >= 0 {
                        index[axis] += 1
                        if index[axis] < overlap[axis] { break }
                        index[axis] = 0
                        axis -= 1
                    }
                    if axis < 0 { break }
                }
            }
        }
        return result
    }
}
