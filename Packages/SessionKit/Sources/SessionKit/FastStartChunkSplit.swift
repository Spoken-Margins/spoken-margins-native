import Foundation

extension NarrationChunkPlanner {
    /// The most the first chunk after a fallback may cost to speak, in `spokenCost` units: about 6 s of
    /// speech, so the bundled voice (about 6x real time on the owner's phone in Low Power Mode) has audio ready
    /// in about a second instead of after a full ~12 s chunk (#849).
    public static let fastStartHeadBudget = 90

    /// `chunks` with the chunk that holds `playheadOffset` split in two at a sentence, comma or word boundary
    /// when it costs more than `headBudget`: a short head to start playing, then the rest of the chunk.
    /// The halves carry no article index, so prepared audio and the saved article plan never see them: the
    /// article's own plan stays whatever `spokenPlan` returned. The halves cover exactly the chunk's range.
    public static func splittingFirstChunk(
        of chunks: [SpokenChunk],
        spokenText: String,
        playheadOffset: Int,
        headBudget: Int = fastStartHeadBudget
    ) -> [SpokenChunk] {
        guard let index = chunks.lastIndex(where: {
            $0.startOffset <= playheadOffset && playheadOffset < $0.startOffset + max(1, $0.sourceLength)
        }) else { return chunks }
        let chunk = chunks[index]
        let head = RenderedSpeechChunker.sourceSlice(
            from: spokenText, startOffset: chunk.startOffset, maxCharacters: headBudget)
        guard head.sourceLength > 0, head.sourceLength < chunk.sourceLength else { return chunks }
        let characters = Array(spokenText)
        let tailStart = chunk.startOffset + head.sourceLength
        let chunkEnd = min(characters.count, chunk.startOffset + chunk.sourceLength)
        guard tailStart < chunkEnd else { return chunks }
        let tailText = String(characters[tailStart..<chunkEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.text.isEmpty, !tailText.isEmpty else { return chunks }
        var result = chunks
        result.replaceSubrange(index...index, with: [
            SpokenChunk(startOffset: chunk.startOffset, sourceLength: head.sourceLength,
                        text: head.text, boundary: head.boundary, articleIndex: nil),
            SpokenChunk(startOffset: tailStart, sourceLength: chunk.startOffset + chunk.sourceLength - tailStart,
                        text: tailText, boundary: chunk.boundary, articleIndex: nil),
        ])
        return result
    }
}
