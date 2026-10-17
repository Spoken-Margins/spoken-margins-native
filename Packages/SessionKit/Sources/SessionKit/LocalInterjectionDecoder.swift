import Foundation

/// Reads the on-device model's replies and the summary context the app hands it. Pure parsing, so it is tested on
/// the host (moved from the app target, #318).
public enum LocalInterjectionDecoder {
    public static func summaryPayload(from context: String) -> LocalInterjectionSummaryPayload? {
        if let data = context.data(using: .utf8),
           let payload = try? JSONDecoder().decode(LocalInterjectionSummaryPayload.self, from: data) {
            return payload
        }
        var partials: [String] = []
        var current: [String] = []
        var sawPartialHeader = false
        for line in context.components(separatedBy: .newlines) {
            if line.range(of: #"^PARTIAL \d+:\s*$"#, options: .regularExpression) != nil {
                if sawPartialHeader {
                    let partial = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty { partials.append(partial) }
                }
                sawPartialHeader = true
                current = []
            } else if sawPartialHeader {
                current.append(line)
            }
        }
        if sawPartialHeader {
            let partial = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty { partials.append(partial) }
        }
        guard !partials.isEmpty else { return nil }
        return LocalInterjectionSummaryPayload(
            schemaVersion: "local-interjection-summary-partials.v1",
            itemTitle: "Partial listener-note summaries",
            interjections: partials.enumerated().map { index, partial in
                LocalInterjectionSummaryRecord(
                    id: "partial-\(index + 1)",
                    anchorBefore: "",
                    anchorAfter: "",
                    note: String(partial.prefix(1_200))
                )
            }
        )
    }

    public static func decodePlainTextPoints(_ raw: String) throws -> [String] {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = candidate.firstIndex(of: "["), let last = candidate.lastIndex(of: "]") {
            candidate = String(candidate[first...last])
        }
        guard let data = candidate.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        let decodedPoints = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var points: [String] = []
        for point in decodedPoints where !points.contains(where: {
            LocalInterjectionSummaryPolicy.semanticSimilarity(point, $0) >= 0.85
        }) {
            points.append(point)
        }
        guard !points.isEmpty, points.count <= 3 else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        return points
    }

    public static func decodeInterjectionMeaningSlots(_ raw: String, source: String) throws -> [String] {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = candidate.firstIndex(of: "{"), let last = candidate.lastIndex(of: "}") {
            candidate = String(candidate[first...last])
        }
        guard let data = candidate.data(using: .utf8),
              let slots = try? JSONDecoder().decode(LocalInterjectionMeaningSlots.self, from: data) else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        let implicitQuestion = implicitQuestion(in: source)
        let sourceAsksQuestion = source.contains("?") || implicitQuestion != nil
        var rawPoints = slots.points
        if let implicitQuestion {
            rawPoints.insert(implicitQuestion, at: 0)
        } else if sourceAsksQuestion,
                  let question = slots.question?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty {
            rawPoints.insert(question.hasSuffix("?") ? question : question + "?", at: 0)
        }
        var points: [String] = []
        for rawPoint in rawPoints {
            let point = LocalInterjectionSummaryPolicy.cleanSpokenNote(rawPoint)
            guard !point.isEmpty else { continue }
            if !points.contains(where: {
                LocalInterjectionSummaryPolicy.semanticSimilarity(point, $0) >= 0.85
            }) {
                points.append(point)
            }
        }
        // The schema permits one question plus as many as four non-question
        // points. Count those typed slots separately instead of rejecting a
        // valid five-element combined list.
        guard !points.isEmpty, points.count <= 7 else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        return points
    }

    private static func implicitQuestion(in source: String) -> String? {
        guard let wonderRange = source.range(
            of: #"(?i)\bi\s+wonder\b"#,
            options: .regularExpression
        ) else { return nil }
        let tail = source[wonderRange.lowerBound...]
        let end = tail.firstIndex(where: { ".!?".contains($0) }) ?? tail.endIndex
        var question = LocalInterjectionSummaryPolicy.cleanSpokenNote(String(tail[..<end]))
        guard !question.isEmpty else { return nil }
        if !question.hasSuffix("?") { question += "?" }
        return question
    }

    public static func decodeLabel(_ raw: String) throws -> LocalListeningMapLabel {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate = candidate
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = candidate.firstIndex(of: "{"),
           let last = candidate.lastIndex(of: "}") {
            candidate = String(candidate[first...last])
        }
        return try JSONDecoder().decode(LocalListeningMapLabel.self, from: Data(candidate.utf8))
    }
}
