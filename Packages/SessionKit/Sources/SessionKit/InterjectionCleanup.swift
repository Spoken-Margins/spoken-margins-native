import Foundation

public struct InterjectionCleanupResult: Codable, Equatable, Sendable {
    public let policyVersion: String
    public let cleanedTranscript: String
    public let decisions: [InterjectionCleanupDecision]

    public init(
        policyVersion: String = "cleanup.v1",
        cleanedTranscript: String,
        decisions: [InterjectionCleanupDecision]
    ) {
        self.policyVersion = policyVersion
        self.cleanedTranscript = cleanedTranscript
        self.decisions = decisions
    }
}

public struct BoundedAnchorContext: Equatable, Sendable {
    public static let maximumCharactersPerSide = 500
    public static let maximumExactTextCharacters = 1_000

    public let before: String
    public let after: String

    public static func select(
        before: String,
        after: String,
        maximumCharactersPerSide: Int = maximumCharactersPerSide
    ) -> BoundedAnchorContext {
        let maximum = max(0, maximumCharactersPerSide)
        let normalizedBefore = normalizedWhitespace(before)
        let normalizedAfter = normalizedWhitespace(after)
        return BoundedAnchorContext(
            before: String(normalizedBefore.suffix(maximum)),
            after: String(normalizedAfter.prefix(maximum))
        )
    }

    static func normalizedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public enum DeterministicInterjectionCleanup {
    public static let policyVersion = "cleanup.v1"
    public static let longPauseThresholdMs = 750
    public static let retainedPauseMs = 250
    public static let fillerPaddingMs = 40
    public static let isolatedPhraseBoundaryMs = 250
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    private static let unambiguousFillers: Set<String> = [
        "um", "uhm", "uh", "ah", "ahh", "er", "erm"
    ]

    public static func propose(
        _ transcript: AlignedInterjectionTranscript,
        restoredDecisionIds: Set<String> = [],
        manuallyDeletedSegmentIds: Set<String> = []
    ) -> InterjectionCleanupResult {
        let segments = transcript.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.endMs > $0.startMs }
            .sorted { lhs, rhs in
                lhs.startMs == rhs.startMs ? lhs.id < rhs.id : lhs.startMs < rhs.startMs
            }
        guard !segments.isEmpty else {
            return InterjectionCleanupResult(cleanedTranscript: transcript.text, decisions: [])
        }

        var decisions: [InterjectionCleanupDecision] = []
        var removedIndices: Set<Int> = []

        for (index, segment) in segments.enumerated() {
            let token = normalizedLexeme(segment.text)
            guard unambiguousFillers.contains(token) else { continue }
            let id = decisionId(kind: "filler", index: index, startMs: segment.startMs, endMs: segment.endMs)
            let accepted = !restoredDecisionIds.contains(id)
            decisions.append(InterjectionCleanupDecision(
                id: id,
                kind: .filler,
                startMs: paddedStart(for: index, in: segments),
                endMs: paddedEnd(for: index, in: segments),
                originalText: segment.text,
                accepted: accepted
            ))
            if accepted { removedIndices.insert(index) }
        }

        for (index, segment) in segments.enumerated() where manuallyDeletedSegmentIds.contains(segment.id) {
            let id = decisionId(kind: "manual-word", index: index, startMs: segment.startMs, endMs: segment.endMs)
            decisions.append(InterjectionCleanupDecision(
                id: id,
                kind: .manualWord,
                startMs: paddedStart(for: index, in: segments),
                endMs: paddedEnd(for: index, in: segments),
                originalText: segment.text,
                accepted: true
            ))
            removedIndices.insert(index)
        }

        if segments.count >= 2 {
            for index in 0..<(segments.count - 1) {
                guard normalizedLexeme(segments[index].text) == "you",
                      normalizedLexeme(segments[index + 1].text) == "know",
                      isIsolatedPhrase(startIndex: index, endIndex: index + 1, in: segments) else { continue }
                let id = decisionId(
                    kind: "you-know",
                    index: index,
                    startMs: segments[index].startMs,
                    endMs: segments[index + 1].endMs
                )
                let accepted = !restoredDecisionIds.contains(id)
                decisions.append(InterjectionCleanupDecision(
                    id: id,
                    kind: .isolatedPhrase,
                    startMs: paddedStart(for: index, in: segments),
                    endMs: paddedEnd(for: index + 1, in: segments),
                    originalText: "\(segments[index].text) \(segments[index + 1].text)",
                    accepted: accepted
                ))
                if accepted {
                    removedIndices.insert(index)
                    removedIndices.insert(index + 1)
                }
            }
        }

        if segments.count >= 2 {
            for index in 0..<(segments.count - 1) {
                let gap = segments[index + 1].startMs - segments[index].endMs
                guard gap > longPauseThresholdMs else { continue }
                let removalStart = segments[index].endMs + retainedPauseMs
                guard removalStart < segments[index + 1].startMs else { continue }
                let id = decisionId(
                    kind: "pause",
                    index: index,
                    startMs: removalStart,
                    endMs: segments[index + 1].startMs
                )
                decisions.append(InterjectionCleanupDecision(
                    id: id,
                    kind: .longPause,
                    startMs: removalStart,
                    endMs: segments[index + 1].startMs,
                    accepted: !restoredDecisionIds.contains(id)
                ))
            }
        }

        let retainedText = segments.enumerated()
            .filter { !removedIndices.contains($0.offset) }
            .map { $0.element.text }
        let cleaned = normalizeTranscriptSpacing(retainedText.joined(separator: " "))
        if cleaned.isEmpty {
            decisions = decisions.map { decision in
                guard decision.accepted, decision.kind != .longPause else { return decision }
                return InterjectionCleanupDecision(
                    id: decision.id,
                    kind: decision.kind,
                    startMs: decision.startMs,
                    endMs: decision.endMs,
                    originalText: decision.originalText,
                    accepted: false
                )
            }
        }
        return InterjectionCleanupResult(
            cleanedTranscript: cleaned.isEmpty ? transcript.text : cleaned,
            decisions: decisions.sorted { lhs, rhs in
                lhs.startMs == rhs.startMs ? lhs.id < rhs.id : lhs.startMs < rhs.startMs
            }
        )
    }

    public static func acceptedRemovalRanges(
        decisions: [InterjectionCleanupDecision],
        durationMs: Int
    ) -> [Range<Int>] {
        let ranges = decisions
            .filter(\.accepted)
            .compactMap { decision -> Range<Int>? in
                let lower = max(0, min(durationMs, decision.startMs))
                let upper = max(lower, min(durationMs, decision.endMs))
                return upper > lower ? lower..<upper : nil
            }
            .sorted { lhs, rhs in lhs.lowerBound < rhs.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            guard let last = merged.last, range.lowerBound <= last.upperBound else {
                merged.append(range)
                continue
            }
            merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        }
        return merged
    }

    private static func normalizedLexeme(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: normalizationLocale)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased(with: normalizationLocale)
    }

    private static func isIsolatedPhrase(
        startIndex: Int,
        endIndex: Int,
        in segments: [AlignedTranscriptSegment]
    ) -> Bool {
        let boundedBefore = startIndex == 0
            || segments[startIndex].startMs - segments[startIndex - 1].endMs >= isolatedPhraseBoundaryMs
            || hasTrailingBoundaryPunctuation(segments[startIndex - 1].text)
        let boundedAfter = endIndex == segments.count - 1
            || segments[endIndex + 1].startMs - segments[endIndex].endMs >= isolatedPhraseBoundaryMs
            || hasTrailingBoundaryPunctuation(segments[endIndex].text)
        return boundedBefore && boundedAfter
    }

    private static func hasTrailingBoundaryPunctuation(_ value: String) -> Bool {
        guard let last = value.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ",.;:!?—–".contains(last)
    }

    private static func paddedStart(for index: Int, in segments: [AlignedTranscriptSegment]) -> Int {
        let lowerLimit = index > 0 ? segments[index - 1].endMs : 0
        return max(lowerLimit, segments[index].startMs - fillerPaddingMs)
    }

    private static func paddedEnd(for index: Int, in segments: [AlignedTranscriptSegment]) -> Int {
        let upperLimit = index + 1 < segments.count ? segments[index + 1].startMs : Int.max
        return min(upperLimit, segments[index].endMs + fillerPaddingMs)
    }

    private static func decisionId(kind: String, index: Int, startMs: Int, endMs: Int) -> String {
        "cleanup-v1-\(kind)-\(String(format: "%04d", index))-\(startMs)-\(endMs)"
    }

    private static func normalizeTranscriptSpacing(_ value: String) -> String {
        var text = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
