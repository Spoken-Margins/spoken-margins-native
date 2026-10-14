import Foundation

/// How Pocket TTS wants its text: tidied, then cut into pieces of at most `maxTokensPerChunk`
/// tokens, at sentence ends where it can and at commas where a sentence alone is too long. This is
/// the export's own reference procedure (`pocket_tts_onnx.py`), step for step.
struct PocketTextPreparation: Sendable {
    let tokenizer: PocketSentencePiece
    let maxTokensPerChunk: Int

    /// One piece of text ready for the model.
    struct Chunk: Equatable, Sendable {
        var text: String
        var tokenIDs: [Int]
        /// Frames of audio to keep generating after the model says it has reached the end.
        var framesAfterEnd: Int
    }

    /// The text as the model is shown it, and how many frames to allow after its end signal.
    func prepare(_ text: String) -> (text: String, framesAfterEndGuess: Int)? {
        var prepared = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prepared.isEmpty else { return nil }
        prepared = prepared
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        let wordCount = prepared.split(whereSeparator: \.isWhitespace).count
        let guess = wordCount <= 4 ? 3 : 1
        if let first = prepared.first, !first.isUppercase {
            prepared = first.uppercased() + prepared.dropFirst()
        }
        if let last = prepared.last, last.isLetter || last.isNumber {
            prepared += "."
        }
        return (prepared, guess)
    }

    func chunks(for text: String) -> [Chunk] {
        guard let whole = prepare(text) else { return [] }
        return sentences(in: whole.text).compactMap { sentence in
            guard let prepared = prepare(sentence) else { return nil }
            let ids = tokenizer.encode(prepared.text)
            guard !ids.isEmpty else { return nil }
            return Chunk(text: prepared.text, tokenIDs: ids, framesAfterEnd: prepared.framesAfterEndGuess + 2)
        }
    }

    private func sentences(in prepared: String) -> [String] {
        let tokens = tokenizer.encode(prepared.trimmingCharacters(in: .whitespacesAndNewlines))
        let sentenceEnds = Set(tokenizer.encode(".!...?").dropFirst())
        let softBreaks = Set(tokenizer.encode(",;:").dropFirst())

        var refined: [(count: Int, text: String)] = []
        for segment in segments(of: tokens, breakingAfter: sentenceEnds) {
            if segment.count <= maxTokensPerChunk {
                refined.append(segment)
                continue
            }
            let subTokens = tokenizer.encode(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            let parts = segments(of: subTokens, breakingAfter: softBreaks)
            if parts.count > 1 {
                refined.append(contentsOf: parts)
            } else {
                refined.append(segment)
            }
        }

        var chunks: [String] = []
        var current = ""
        var currentCount = 0
        for segment in refined {
            if current.isEmpty {
                current = segment.text
                currentCount = segment.count
            } else if currentCount + segment.count > maxTokensPerChunk {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = segment.text
                currentCount = segment.count
            } else {
                current += " " + segment.text
                currentCount += segment.count
            }
        }
        if !current.isEmpty { chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return chunks
    }

    /// Cuts `tokens` after each run of break tokens, where the next token starts something new.
    private func segments(of tokens: [Int], breakingAfter breakTokens: Set<Int>) -> [(count: Int, text: String)] {
        var starts = [0]
        var previousWasBreak = false
        for (index, token) in tokens.enumerated() {
            if breakTokens.contains(token) {
                previousWasBreak = true
            } else {
                if previousWasBreak { starts.append(index) }
                previousWasBreak = false
            }
        }
        starts.append(tokens.count)
        return zip(starts, starts.dropFirst()).map { start, end in
            (end - start, tokenizer.decode(Array(tokens[start..<end])))
        }
    }
}
