import Foundation

/// Letter-to-sound for words no dictionary has: g2p_en's GRU encoder-decoder (Apache-2.0 weights trained
/// on CMUdict), as plain matrix math. A port of `research/C2/frontend/neural_g2p.py`. Output is CMUdict
/// ARPAbet with stress digits. The weights are one float32 little-endian blob plus a JSON manifest.
public final class NeuralLetterToSound: Sendable {
    private struct ManifestEntry: Decodable {
        let name: String
        let shape: [Int]
        let offset: Int
        let bytes: Int
    }

    private struct Matrix: Sendable {
        let rows: Int
        let columns: Int
        let values: [Float]

        /// `self * vector`, plus `bias`.
        func apply(_ vector: [Float], bias: [Float]) -> [Float] {
            var out = bias
            values.withUnsafeBufferPointer { weights in
                vector.withUnsafeBufferPointer { input in
                    out.withUnsafeMutableBufferPointer { result in
                        for row in 0..<rows {
                            var sum: Float = 0
                            let base = row * columns
                            for column in 0..<columns { sum += weights[base + column] * input[column] }
                            result[row] += sum
                        }
                    }
                }
            }
            return out
        }

        func row(_ index: Int) -> [Float] { Array(values[(index * columns)..<((index + 1) * columns)]) }
    }

    public enum LoadError: Error, Equatable { case missingWeight(String) }

    private let weights: [String: Matrix]
    private let hiddenSize: Int
    private let graphemeIndex: [String: Int]

    public init(weightsURL: URL, manifestURL: URL) throws {
        let manifest = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: manifestURL))
        let blob = try Data(contentsOf: weightsURL, options: .alwaysMapped)
        var loaded: [String: Matrix] = [:]
        for entry in manifest {
            let count = entry.bytes / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: count)
            values.withUnsafeMutableBytes { destination in
                _ = blob.copyBytes(to: destination, from: entry.offset..<(entry.offset + entry.bytes))
            }
            loaded[entry.name] = Matrix(rows: entry.shape.count > 1 ? entry.shape[0] : 1,
                                        columns: entry.shape.count > 1 ? entry.shape[1] : entry.shape[0], values: values)
        }
        for name in ["enc_emb", "enc_w_ih", "enc_w_hh", "enc_b_ih", "enc_b_hh", "dec_emb", "dec_w_ih", "dec_w_hh",
                     "dec_b_ih", "dec_b_hh", "fc_w", "fc_b"] where loaded[name] == nil {
            throw LoadError.missingWeight(name)
        }
        weights = loaded
        hiddenSize = loaded["enc_w_hh"]!.columns
        graphemeIndex = Dictionary(uniqueKeysWithValues: FrontEndTables.g2pGraphemes.enumerated().map { ($1, $0) })
    }

    private func cell(_ x: [Float], _ h: [Float], prefix: String) -> [Float] {
        let inputGates = weights[prefix + "_w_ih"]!.apply(x, bias: weights[prefix + "_b_ih"]!.values)
        let hiddenGates = weights[prefix + "_w_hh"]!.apply(h, bias: weights[prefix + "_b_hh"]!.values)
        let n = inputGates.count / 3
        var next = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let reset = 1 / (1 + exp(-(inputGates[i] + hiddenGates[i])))
            let update = 1 / (1 + exp(-(inputGates[n + i] + hiddenGates[n + i])))
            let candidate = tanh(inputGates[2 * n + i] + reset * hiddenGates[2 * n + i])
            next[i] = (1 - update) * candidate + update * h[i]
        }
        return next
    }

    /// The pronunciation of a lowercase word of letters a to z, as ARPAbet phones with stress digits.
    public func phones(for word: String) -> [String] {
        var hidden = [Float](repeating: 0, count: hiddenSize)
        let encoderEmbedding = weights["enc_emb"]!
        for letter in word.lowercased().map(String.init) + ["</s>"] {
            hidden = cell(encoderEmbedding.row(graphemeIndex[letter] ?? 1), hidden, prefix: "enc")
        }
        let decoderEmbedding = weights["dec_emb"]!
        var input = decoderEmbedding.row(2)                       // <s>
        var out: [String] = []
        for _ in 0..<20 {
            hidden = cell(input, hidden, prefix: "dec")
            let scores = weights["fc_w"]!.apply(hidden, bias: weights["fc_b"]!.values)
            var best = 0
            for index in 1..<scores.count where scores[index] > scores[best] { best = index }
            if best == 3 { break }                                // </s>
            out.append(FrontEndTables.g2pPhonemes[best])
            input = decoderEmbedding.row(best)
        }
        return out
    }
}
