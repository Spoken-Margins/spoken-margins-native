import Foundation

extension NarrationChunkPlanner {
    /// Names one chunk of one plan, for the player's per-chunk state (rendered audio, renders in flight, durations).
    ///
    /// A start offset used to be enough, because no two chunks of a plan began at the same spoken character. An aside
    /// (#3777) adds no source characters, so it starts where the next body chunk starts, and two chunks can share
    /// an offset. The key adds the chunk's place among the chunks that begin at that offset: `ordinal` is the number
    /// of earlier chunks in the plan with the same start. A plan with no aside has an ordinal of 0 on every chunk, so
    /// its keys are its start offsets as before. Keys compare in plan order.
    public struct ChunkKey: Hashable, Comparable, Sendable {
        public var startOffset: Int
        public var ordinal: Int

        public init(startOffset: Int, ordinal: Int = 0) {
            self.startOffset = startOffset
            self.ordinal = ordinal
        }

        public static func < (lhs: ChunkKey, rhs: ChunkKey) -> Bool {
            (lhs.startOffset, lhs.ordinal) < (rhs.startOffset, rhs.ordinal)
        }
    }

    /// The key of each of `chunks`, in order. Unique within the array; the same array always gives the same keys,
    /// and a chunk that is split in two for a quick start (`splittingFirstChunk`) keeps its place, so its head has
    /// the key the whole chunk had.
    public static func chunkKeys(for chunks: [SpokenChunk]) -> [ChunkKey] {
        var seen: [Int: Int] = [:]
        return chunks.map { chunk in
            let ordinal = seen[chunk.startOffset, default: 0]
            seen[chunk.startOffset] = ordinal + 1
            return ChunkKey(startOffset: chunk.startOffset, ordinal: ordinal)
        }
    }
}

extension NarrationChunkPlanner.SpokenChunk {
    /// An inserted chunk that reads a note after the sentence that cites it (#3777). It has no source characters, so
    /// it never holds a playhead position: only the player's step from the chunk before reaches it.
    public var isAside: Bool {
        if case .aside = footnote { return true }
        return false
    }
}
