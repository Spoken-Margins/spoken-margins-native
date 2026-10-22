import Foundation

/// Where in the source a live session's Margin falls (#1989, #2481), from what the listener told us: their
/// position when the session started and, if they gave it, when it ended.
///
/// position = startPosition + (wall time − session start) × rate, where rate = (endPosition − startPosition) /
/// (session end − session start) when there is an end position, else 1. The rate absorbs a playback speed
/// (1.5×) and pauses as one average, and the result is clamped to [startPosition, endPosition]. Every such
/// position is approximate ("about 1:23:10"). Text-match anchors from an imported transcript are exact, and
/// between two of them the position follows a straight line from one to the next, overriding the estimate.
public enum LiveSessionPositionMap {
    public enum Failure: Error, Equatable, LocalizedError {
        case endBeforeStart

        public var errorDescription: String? {
            "The end time is before the start time. Check where you were when you started and stopped."
        }
    }

    public struct Anchor: Equatable, Sendable {
        public var wallTime: Date
        public var positionMs: Int

        public init(wallTime: Date, positionMs: Int) {
            self.wallTime = wallTime
            self.positionMs = positionMs
        }
    }

    public struct Position: Equatable, Sendable {
        public var ms: Int
        public var isApproximate: Bool

        /// "about 1:23:10", or "1:23:10" for a position pinned by a transcript match.
        public var label: String {
            (isApproximate ? "about " : "") + LiveSessionPositionMap.clock(ms)
        }
    }

    /// Rejects an end position before the start position.
    public static func validate(startPositionMs: Int?, endPositionMs: Int?) throws {
        if let start = startPositionMs, let end = endPositionMs, end < start { throw Failure.endBeforeStart }
    }

    /// The average source time per wall time: 1 without an end position or an ended session.
    public static func rate(for session: LiveSession) -> Double {
        guard let startPosition = session.startPositionMs, let endPosition = session.endPositionMs, endPosition >= startPosition,
              let endedAt = session.endedAt else { return 1 }
        let wallMs = endedAt.timeIntervalSince(session.startedAt) * 1_000
        guard wallMs > 0 else { return 1 }
        return Double(endPosition - startPosition) / wallMs
    }

    /// The source position at `wallTime`, or nil when the listener gave no start position and no anchor covers it.
    public static func position(at wallTime: Date, in session: LiveSession, anchors: [Anchor] = []) -> Position? {
        let sorted = anchors.sorted { $0.wallTime < $1.wallTime }
        if let exact = sorted.first(where: { abs($0.wallTime.timeIntervalSince(wallTime)) < 0.001 }) {
            return Position(ms: exact.positionMs, isApproximate: false)
        }
        if let after = sorted.firstIndex(where: { $0.wallTime > wallTime }), after > 0 {
            let lower = sorted[after - 1]
            let upper = sorted[after]
            let fraction = wallTime.timeIntervalSince(lower.wallTime) / upper.wallTime.timeIntervalSince(lower.wallTime)
            let ms = Double(lower.positionMs) + fraction * Double(upper.positionMs - lower.positionMs)
            return Position(ms: Int(ms.rounded()), isApproximate: true)
        }
        guard let startPosition = session.startPositionMs else { return nil }
        let elapsedMs = max(0, wallTime.timeIntervalSince(session.startedAt) * 1_000)
        var ms = Int((Double(startPosition) + elapsedMs * rate(for: session)).rounded())
        ms = max(startPosition, ms)
        if let endPosition = session.endPositionMs, endPosition >= startPosition { ms = min(endPosition, ms) }
        return Position(ms: ms, isApproximate: true)
    }

    /// "1:23:10" or "4:05". Reads "h:mm:ss", "m:ss" or plain minutes ("2" is 2:00) back with `parse`.
    public static func clock(_ ms: Int) -> String {
        let seconds = max(0, ms / 1_000)
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber), let minutes = Int(trimmed) { return minutes * 60_000 }
        return TranscriptImport.clockMs(trimmed)
    }
}
