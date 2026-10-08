import Foundation

/// The time between one narration chunk finishing and the next one starting to play (#586).
///
/// The player makes a new item for every chunk, so each seam costs the planned transition delay,
/// the time to set the next item up, and, when the next chunk hasn't been rendered yet, the wait
/// for it. Diagnostics keep the longest such gap so a report from the phone says which seam was bad
/// and whether it was waiting on the renderer or the player. Silence inside a chunk's own audio
/// isn't part of this; `SpeechSilenceTrim` removes most of that.
public struct ChunkHandOverGapRecorder: Sendable {
    public struct Gap: Equatable, Sendable {
        public var seconds: TimeInterval
        /// How the chunk that finished ended.
        public var boundary: RenderedSpeechChunkBoundary
        /// False when the player had to wait for the next chunk to render.
        public var nextChunkWasReady: Bool

        public init(seconds: TimeInterval, boundary: RenderedSpeechChunkBoundary, nextChunkWasReady: Bool) {
            self.seconds = seconds
            self.boundary = boundary
            self.nextChunkWasReady = nextChunkWasReady
        }

        /// For diagnostics: `0.42s after sentence, next chunk ready`.
        public var summary: String {
            let rounded = String(format: "%.2f", seconds)
            return "\(rounded)s after \(boundary.rawValue), "
                + (nextChunkWasReady ? "next chunk ready" : "waited for next chunk")
        }
    }

    private struct Pending {
        var finishedAt: TimeInterval
        var generation: UUID
        var boundary: RenderedSpeechChunkBoundary
        var nextChunkWasReady: Bool
    }

    /// The longest gap recorded so far.
    public private(set) var longest: Gap?
    private var pending: Pending?

    public init() {}

    /// A chunk finished and another follows. `time` is any monotonic clock, in seconds.
    public mutating func chunkFinished(
        at time: TimeInterval,
        generation: UUID,
        boundary: RenderedSpeechChunkBoundary,
        nextChunkWasReady: Bool
    ) {
        pending = Pending(
            finishedAt: time, generation: generation, boundary: boundary, nextChunkWasReady: nextChunkWasReady
        )
    }

    /// A chunk started playing. Returns the gap that just closed when it is the longest so far.
    /// A first chunk, or one that follows a pause, stop or seek (another generation), has no gap.
    @discardableResult
    public mutating func chunkStarted(at time: TimeInterval, generation: UUID) -> Gap? {
        guard let finished = pending else { return nil }
        pending = nil
        guard finished.generation == generation else { return nil }
        let gap = Gap(
            seconds: max(0, time - finished.finishedAt),
            boundary: finished.boundary,
            nextChunkWasReady: finished.nextChunkWasReady
        )
        guard gap.seconds > (longest?.seconds ?? -1) else { return nil }
        longest = gap
        return gap
    }

    /// The listener paused, so the time until the next start isn't a hand-over.
    public mutating func discardPending() {
        pending = nil
    }
}
