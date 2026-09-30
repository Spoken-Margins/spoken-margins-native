import Foundation

public struct SourceAnchorContext: Equatable, Sendable {
    public var anchorBefore: String
    public var anchorAfter: String
    public var transcriptSegmentId: String?
    public var startChar: Int
    public var endChar: Int

    public init(
        anchorBefore: String,
        anchorAfter: String,
        transcriptSegmentId: String?,
        startChar: Int,
        endChar: Int
    ) {
        self.anchorBefore = anchorBefore
        self.anchorAfter = anchorAfter
        self.transcriptSegmentId = transcriptSegmentId
        self.startChar = startChar
        self.endChar = endChar
    }
}

/// Resolves the human-readable source passage surrounding a native-audio interjection.
///
/// The media timestamp and transcript segment remain the durable machine anchor. These
/// strings reconstruct the listening moment for a person, so they intentionally retain
/// a substantial time-based shoulder instead of being reduced to locator snippets.
public enum SourceAnchorContextResolver {
    public static let windowBeforeMs = 90_000
    public static let windowAfterMs = 120_000

    /// Short timed transcript segments are the smallest honest alignment unit. Longer
    /// segments (including a whole episode attached as one text/plain segment) are split
    /// proportionally so that the passage still corresponds to the requested media time.
    private static let indivisibleSegmentDurationMs = 30_000

    public static func resolve(
        mediaTimeMs: Int,
        timeline: TranscriptTimeline,
        windowBeforeMs: Int = windowBeforeMs,
        windowAfterMs: Int = windowAfterMs
    ) -> SourceAnchorContext? {
        let mediaTimeMs = max(0, mediaTimeMs)
        let windowStartMs = max(0, mediaTimeMs - max(0, windowBeforeMs))
        let durationBoundary = timeline.durationMs ?? Int.max
        let windowEndMs = min(durationBoundary, mediaTimeMs + max(0, windowAfterMs))
        let segments = timeline.segments
            .filter { $0.endMs >= windowStartMs && $0.startMs <= windowEndMs }
            .sorted { lhs, rhs in
                lhs.startMs == rhs.startMs ? lhs.endMs < rhs.endMs : lhs.startMs < rhs.startMs
            }
        guard !segments.isEmpty else { return nil }

        let resolved = MediaTimelineAnchorResolver.resolve(mediaTimeMs: mediaTimeMs, timeline: timeline)
        var beforeParts: [String] = []
        var afterParts: [String] = []

        for segment in segments {
            let segmentStart = max(0, segment.startMs)
            let segmentEnd = max(segmentStart + 1, segment.endMs)
            let selectedStart = max(segmentStart, windowStartMs)
            let selectedEnd = min(segmentEnd, windowEndMs)
            guard selectedEnd > selectedStart else { continue }

            let containsInterjection = segmentStart <= mediaTimeMs && mediaTimeMs < segmentEnd
            if containsInterjection, segmentEnd - segmentStart <= indivisibleSegmentDurationMs {
                if let text = slice(
                    segment.text,
                    segmentStartMs: segmentStart,
                    segmentEndMs: segmentEnd,
                    selectionStartMs: selectedStart,
                    selectionEndMs: selectedEnd
                ) {
                    // A short timed segment is the closest supported human-readable unit.
                    // Keep it intact before the marker instead of pretending to know the
                    // exact word boundary within a coarse transcript segment.
                    beforeParts.append(text)
                }
                continue
            }

            let beforeEnd = min(selectedEnd, mediaTimeMs)
            if beforeEnd > selectedStart,
               let text = slice(
                   segment.text,
                   segmentStartMs: segmentStart,
                   segmentEndMs: segmentEnd,
                   selectionStartMs: selectedStart,
                   selectionEndMs: beforeEnd
               ) {
                beforeParts.append(text)
            }

            let afterStart = max(selectedStart, mediaTimeMs)
            if selectedEnd > afterStart,
               let text = slice(
                   segment.text,
                   segmentStartMs: segmentStart,
                   segmentEndMs: segmentEnd,
                   selectionStartMs: afterStart,
                   selectionEndMs: selectedEnd
               ) {
                afterParts.append(text)
            }
        }

        let before = joined(beforeParts)
        let after = joined(afterParts)
        guard !before.isEmpty || !after.isEmpty else { return nil }
        return SourceAnchorContext(
            anchorBefore: before,
            anchorAfter: after,
            transcriptSegmentId: resolved.transcriptSegmentId,
            startChar: resolved.startChar,
            endChar: resolved.endChar
        )
    }

    private static func slice(
        _ source: String,
        segmentStartMs: Int,
        segmentEndMs: Int,
        selectionStartMs: Int,
        selectionEndMs: Int
    ) -> String? {
        let normalized = normalizedWhitespace(source)
        guard !normalized.isEmpty else { return nil }
        let characters = Array(normalized)
        let duration = max(1, segmentEndMs - segmentStartMs)
        let lowerFraction = Double(max(segmentStartMs, selectionStartMs) - segmentStartMs) / Double(duration)
        let upperFraction = Double(min(segmentEndMs, selectionEndMs) - segmentStartMs) / Double(duration)
        var lower = max(0, min(characters.count, Int(floor(lowerFraction * Double(characters.count)))))
        var upper = max(lower, min(characters.count, Int(ceil(upperFraction * Double(characters.count)))))

        if lower > 0, lower < characters.count,
           !characters[lower - 1].isWhitespace, !characters[lower].isWhitespace {
            while lower < upper, !characters[lower].isWhitespace { lower += 1 }
            while lower < upper, characters[lower].isWhitespace { lower += 1 }
        }
        if upper > lower, upper < characters.count,
           !characters[upper - 1].isWhitespace, !characters[upper].isWhitespace {
            while upper > lower, !characters[upper - 1].isWhitespace { upper -= 1 }
        }
        guard upper > lower else { return nil }
        let result = String(characters[lower..<upper])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func normalizedWhitespace(_ source: String) -> String {
        source
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func joined(_ parts: [String]) -> String {
        normalizedWhitespace(parts.joined(separator: " "))
    }
}
