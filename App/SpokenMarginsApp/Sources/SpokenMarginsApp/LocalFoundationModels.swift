import Foundation
import NaturalLanguage
import SessionKit

#if canImport(FoundationModels)
import FoundationModels
#endif

struct SpokenMarginsFeatureFlags: Equatable, Sendable {
    static let remoteProviderInfoKey = "SMRemoteProviderExperienceEnabled"

    let remoteProviderExperienceEnabled: Bool

    static var release: SpokenMarginsFeatureFlags {
        SpokenMarginsFeatureFlags(
            remoteProviderExperienceEnabled: Bundle.main.object(
                forInfoDictionaryKey: remoteProviderInfoKey
            ) as? Bool ?? false
        )
    }
}

enum LocalFoundationModelAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .available:
            return "Available on this device"
        case .unavailable(let reason):
            return reason
        }
    }
}

struct LocalListeningMapLabel: Codable, Equatable, Sendable {
    let title: String
    let description: String
}

struct LocalInterjectionSummaryRecord: Codable, Equatable, Sendable {
    let id: String
    let anchorBefore: String
    let anchorAfter: String
    let note: String
}

struct LocalInterjectionSummaryPayload: Codable, Equatable, Sendable {
    let schemaVersion: String
    let itemTitle: String
    let interjections: [LocalInterjectionSummaryRecord]
}

enum LocalInterjectionSummaryPolicy {
    static let anchorCharacterLimit = 240

    static func cleanSpokenNote(_ note: String) -> String {
        var cleaned = note
        cleaned = replacing(
            #"(?i)\b(?:um+|uh+|er+|ah+|hmm+)\b[\s,;:—–-]*"#,
            in: cleaned,
            with: ""
        )
        cleaned = replacing(
            #"(?i)\b([[:alpha:]][[:alnum:]’']*)\b(?:[\s,;:—–-]+\1\b)+"#,
            in: cleaned,
            with: "$1"
        )
        cleaned = replacing(#"\s+([,.!?;:])"#, in: cleaned, with: "$1")
        cleaned = replacing(#"([,;:]){2,}"#, in: cleaned, with: "$1")
        cleaned = replacing(#"\s{2,}"#, in: cleaned, with: " ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static func boundedAnchorBefore(_ anchor: String) -> String {
        String(anchor.suffix(anchorCharacterLimit))
    }

    static func boundedAnchorAfter(_ anchor: String) -> String {
        String(anchor.prefix(anchorCharacterLimit))
    }

    static func validate(bullets: [String], payload: LocalInterjectionSummaryPayload) throws -> [String] {
        let cleaned = bullets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty, cleaned.count <= payload.interjections.count else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        let filler = try NSRegularExpression(pattern: #"(?i)\b(?:um+|uh+|er+|ah+|hmm+)\b"#)
        let longestListenerNote = payload.interjections
            .map { normalizedWords($0.note).count }
            .max() ?? 0
        let maximumBulletWords = max(35, min(120, longestListenerNote))
        for bullet in cleaned {
            let range = NSRange(bullet.startIndex..<bullet.endIndex, in: bullet)
            guard filler.firstMatch(in: bullet, range: range) == nil,
                  bullet.split(whereSeparator: { $0.isWhitespace }).count <= maximumBulletWords else {
                throw LocalFoundationModelError.invalidInterjectionSummary
            }
            for record in payload.interjections {
                if sharesLongPhrase(bullet, with: record.anchorBefore)
                    || sharesLongPhrase(bullet, with: record.anchorAfter) {
                    throw LocalFoundationModelError.invalidInterjectionSummary
                }
            }
        }
        return cleaned
    }

    static func fallbackRewrite(for record: LocalInterjectionSummaryRecord) throws -> String {
        let cleaned = cleanSpokenNote(record.note)
        guard !cleaned.isEmpty else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        // This fallback is derived only from the listener-authored note. It cannot copy
        // source anchors or answer the listener, and it keeps one difficult model output
        // from discarding every other valid note in the session.
        return cleaned
    }

    private static func replacing(_ pattern: String, in source: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.stringByReplacingMatches(in: source, range: range, withTemplate: replacement)
    }

    private static func sharesLongPhrase(_ output: String, with source: String) -> Bool {
        let outputWords = normalizedWords(output)
        let sourceWords = normalizedWords(source)
        guard outputWords.count >= 7, sourceWords.count >= 7 else { return false }
        let outputText = outputWords.joined(separator: " ")
        for index in 0...(sourceWords.count - 7) {
            if outputText.contains(sourceWords[index..<(index + 7)].joined(separator: " ")) {
                return true
            }
        }
        return false
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "A concise rewrite of one listener note, excluding source excerpts.")
private struct GeneratedInterjectionRewrite {
    @Guide(description: "Only the listener's polished intent. Exclude source anchors, filler words, stutters, repetition, and answers.")
    var rewrittenNote: String
}
#endif

protocol LocalFoundationModelClient: Sendable {
    func availability() -> LocalFoundationModelAvailability
    func summarizeInterjections(context: String) async throws -> String
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String
}

struct AppleFoundationModelClient: LocalFoundationModelClient {
    func availability() -> LocalFoundationModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable("Requires a device that supports Apple Intelligence")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("Turn on Apple Intelligence to use on-device summaries")
            case .unavailable(.modelNotReady):
                return .unavailable("Apple’s on-device model is still downloading or not ready")
            @unknown default:
                return .unavailable("Apple’s on-device model is unavailable")
            }
        }
        #endif
        return .unavailable("Requires iOS 26 or later")
    }

    func summarizeInterjections(context: String) async throws -> String {
        try requireAvailability()
        guard let payload = Self.interjectionSummaryPayload(from: context),
              !payload.interjections.isEmpty else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        return try await respondWithStructuredSummary(payload: payload)
    }

    static func interjectionSummaryPayload(from context: String) -> LocalInterjectionSummaryPayload? {
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

    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        try requireAvailability()
        let prompt = """
        Label this bounded section of a spoken item. Return only JSON with exactly two string fields: "title" and "description". The title must be at most 8 words. The description must be one sentence and at most 28 words. Describe the topic without quoting long passages or reproducing the transcript.

        SECTION \(chapterNumber):
        \(String(text.prefix(6_000)))
        """
        let raw = try await respond(to: prompt, maximumResponseTokens: 160)
        let label = try Self.decodeLabel(raw)
        guard !label.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalFoundationModelError.invalidStructuredResponse
        }
        return label
    }

    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        try requireAvailability()
        let outline = labels.enumerated().map { index, label in
            "\(index + 1). \(label.title): \(label.description)"
        }.joined(separator: "\n")
        let prompt = """
        Write a one-sentence overview, at most 35 words, of this listening map. Use only the chapter labels. Return only the sentence.

        \(outline)
        """
        return try await respond(to: prompt, maximumResponseTokens: 100)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requireAvailability() throws {
        guard availability().isAvailable else {
            throw LocalFoundationModelError.unavailable(availability().description)
        }
    }

    private func respond(to prompt: String, maximumResponseTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(
                model: .default,
                instructions: "Process all content on device. Follow the requested output bounds and never reproduce long source passages."
            )
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: maximumResponseTokens
                )
            )
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LocalFoundationModelError.emptyResponse }
            return text
        }
        #endif
        throw LocalFoundationModelError.unavailable("Requires iOS 26 or later")
    }

    private func respondWithStructuredSummary(payload: LocalInterjectionSummaryPayload) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            var bullets: [String] = []
            for record in payload.interjections {
                let scopedPayload = LocalInterjectionSummaryPayload(
                    schemaVersion: payload.schemaVersion,
                    itemTitle: payload.itemTitle,
                    interjections: [record]
                )
                do {
                    bullets.append(try await rewrite(record: record, payload: scopedPayload, includeAnchors: true))
                } catch {
                    if error is CancellationError { throw error }
                    do {
                        bullets.append(try await rewrite(record: record, payload: scopedPayload, includeAnchors: false))
                    } catch {
                        if error is CancellationError { throw error }
                        bullets.append(try LocalInterjectionSummaryPolicy.fallbackRewrite(for: record))
                    }
                }
            }
            return bullets.map { "- \($0)" }.joined(separator: "\n")
        }
        #endif
        throw LocalFoundationModelError.unavailable("Requires iOS 26 or later")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func rewrite(
        record: LocalInterjectionSummaryRecord,
        payload: LocalInterjectionSummaryPayload,
        includeAnchors: Bool
    ) async throws -> String {
        let session = LanguageModelSession(
            model: .default,
            instructions: "Rewrite only the listener note. Never answer it or output source context."
        )
        let response = try await session.respond(
            to: Self.interjectionRewritePrompt(record: record, includeAnchors: includeAnchors),
            generating: GeneratedInterjectionRewrite.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 120)
        )
        let candidate = response.content.rewrittenNote
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•")))
        return try LocalInterjectionSummaryPolicy.validate(bullets: [candidate], payload: payload)[0]
    }
    #endif

    static func interjectionRewritePrompt(
        record: LocalInterjectionSummaryRecord,
        includeAnchors: Bool
    ) -> String {
        var prompt = """
        Rewrite this single listener note as one concise, polished sentence. Remove fillers, stutters, repeated fragments, false starts, and transcription noise. Preserve viewpoint, meaningful uncertainty, qualifications, questions, preferences, and requested actions. Do not answer the note or add conclusions.

        LISTENER NOTE:
        \(record.note)
        """
        if includeAnchors, !record.anchorBefore.isEmpty || !record.anchorAfter.isEmpty {
            prompt += """


            OPTIONAL SOURCE CONTEXT — use only to resolve references; never copy or summarize it:
            BEFORE: \(record.anchorBefore)
            AFTER: \(record.anchorAfter)
            """
        }
        return prompt
    }

    private static func decodeLabel(_ raw: String) throws -> LocalListeningMapLabel {
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

enum LocalFoundationModelError: LocalizedError, Equatable {
    case unavailable(String)
    case emptyResponse
    case invalidStructuredResponse
    case sourceTextUnavailable
    case outputTooLong
    case excessiveSourceQuotation
    case invalidInterjectionSummary

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyResponse: return "The on-device model returned an empty response."
        case .invalidStructuredResponse: return "The on-device model returned an invalid chapter label."
        case .sourceTextUnavailable: return "No source text is available for a Listening Map."
        case .outputTooLong: return "The on-device model returned chapter metadata outside the allowed length."
        case .excessiveSourceQuotation: return "The on-device model copied too much source text into chapter metadata."
        case .invalidInterjectionSummary: return "The on-device model did not produce a safe, concise listener-note summary."
        }
    }
}

enum LocalListeningMapOutputValidator {
    static func validate(label: LocalListeningMapLabel, sourceText: String) throws -> LocalListeningMapLabel {
        let title = label.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = label.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !description.isEmpty else {
            throw LocalFoundationModelError.invalidStructuredResponse
        }
        guard words(title).count <= 8, words(description).count <= 28 else {
            throw LocalFoundationModelError.outputTooLong
        }
        let generatedWords = words("\(title) \(description)")
        let sourceWords = words(sourceText)
        guard !containsSharedRun(lhs: generatedWords, rhs: sourceWords, length: 10) else {
            throw LocalFoundationModelError.excessiveSourceQuotation
        }
        return LocalListeningMapLabel(title: title, description: description)
    }

    static func validateOverview(_ overview: String) throws -> String {
        let trimmed = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalFoundationModelError.emptyResponse }
        guard words(trimmed).count <= 35 else { throw LocalFoundationModelError.outputTooLong }
        return trimmed
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func containsSharedRun(lhs: [String], rhs: [String], length: Int) -> Bool {
        guard lhs.count >= length, rhs.count >= length else { return false }
        let sourceRuns = Set((0...(rhs.count - length)).map { rhs[$0..<($0 + length)].joined(separator: " ") })
        return (0...(lhs.count - length)).contains { index in
            sourceRuns.contains(lhs[index..<(index + length)].joined(separator: " "))
        }
    }
}

struct AppleFoundationAIProvider: AIProviderClient {
    let providerType = "apple_foundation_on_device"
    let model = "system_language_model"
}

struct LocalListeningMapChapterDraft: Equatable, Sendable {
    let id: String
    let startChar: Int
    let endChar: Int
    let percent: Int
    let startMs: Int?
    let transcriptSegmentId: String?
    let text: String
}

struct LocalListeningMapDraft: Equatable, Sendable {
    let chapters: [LocalListeningMapChapterDraft]
}

struct LocalListeningMapPlanner {
    typealias VectorProvider = @Sendable (String) -> [Double]?

    private struct Unit {
        let startChar: Int
        let endChar: Int
        let startMs: Int?
        let endMs: Int?
        let transcriptSegmentId: String?
        let text: String
    }

    private let vectorProvider: VectorProvider

    init(vectorProvider: @escaping VectorProvider = LocalListeningMapPlanner.sentenceVector) {
        self.vectorProvider = vectorProvider
    }

    func makeDraft(text: String, timeline: TranscriptTimeline?) throws -> LocalListeningMapDraft {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw LocalFoundationModelError.sourceTextUnavailable }
        let units = timeline.flatMap { mediaUnits(text: source, timeline: $0) } ?? textUnits(text: source)
        guard !units.isEmpty else { throw LocalFoundationModelError.sourceTextUnavailable }

        let boundaryScores = (0..<units.count).map { boundary in
            boundary == 0 ? 0 : semanticDissimilarity(units: units, boundary: boundary)
        }
        var starts = [0]
        var chapterStart = 0
        for boundary in 1..<units.count {
            let current = units[chapterStart..<boundary]
            let characterCount = max(0, units[boundary - 1].endChar - units[chapterStart].startChar)
            let duration = boundedDuration(current)
            let reachedMinimum = characterCount >= 2_500 || duration >= 240_000
            let reachedHardLimit = characterCount >= 6_000 || duration >= 720_000
            let topicShift = boundaryScores[boundary]
            let previousScore = boundary > 1 ? boundaryScores[boundary - 1] : 0
            let nextScore = boundary + 1 < boundaryScores.count ? boundaryScores[boundary + 1] : 0
            let isLocalPeak = topicShift >= previousScore && topicShift >= nextScore
            if reachedHardLimit || (reachedMinimum && isLocalPeak && topicShift >= 0.42) {
                starts.append(boundary)
                chapterStart = boundary
            }
        }

        // Avoid a tiny tail that creates a noisy chapter label.
        if starts.count > 1,
           let tailStart = starts.last,
           units.last!.endChar - units[tailStart].startChar < 500,
           boundedDuration(units[tailStart..<units.count]) < 90_000 {
            starts.removeLast()
        }

        let chapters = starts.enumerated().map { index, unitIndex in
            let endUnitIndex = index + 1 < starts.count ? starts[index + 1] : units.count
            let first = units[unitIndex]
            let last = units[endUnitIndex - 1]
            let chapterText = units[unitIndex..<endUnitIndex].map(\.text).joined(separator: " ")
            return LocalListeningMapChapterDraft(
                id: "ch-local-\(String(format: "%02d", index + 1))",
                startChar: first.startChar,
                endChar: last.endChar,
                percent: source.isEmpty ? 0 : max(0, min(100, Int((Double(first.startChar) / Double(source.count) * 100).rounded()))),
                startMs: first.startMs,
                transcriptSegmentId: first.transcriptSegmentId,
                text: chapterText
            )
        }
        return LocalListeningMapDraft(chapters: chapters)
    }

    private func textUnits(text: String) -> [Unit] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var units: [Unit] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return true }
            units.append(Unit(
                startChar: text.distance(from: text.startIndex, to: range.lowerBound),
                endChar: text.distance(from: text.startIndex, to: range.upperBound),
                startMs: nil,
                endMs: nil,
                transcriptSegmentId: nil,
                text: value
            ))
            return true
        }
        if units.isEmpty {
            units.append(Unit(startChar: 0, endChar: text.count, startMs: nil, endMs: nil, transcriptSegmentId: nil, text: text))
        }
        return units
    }

    private func mediaUnits(text: String, timeline: TranscriptTimeline) -> [Unit]? {
        let sorted = timeline.segments.sorted { $0.startMs < $1.startMs }
        guard !sorted.isEmpty else { return nil }
        var cursor = 0
        return sorted.compactMap { segment in
            let value = segment.text
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let start = segment.startChar ?? cursor
            let end = segment.endChar ?? min(text.count, start + value.count)
            cursor = min(text.count, end + 1)
            return Unit(
                startChar: max(0, min(start, text.count)),
                endChar: max(0, min(end, text.count)),
                startMs: segment.startMs,
                endMs: segment.endMs,
                transcriptSegmentId: segment.id,
                text: value
            )
        }
    }

    private func boundedDuration(_ units: ArraySlice<Unit>) -> Int {
        guard let first = units.first?.startMs, let last = units.last?.endMs else { return 0 }
        return max(0, last - first)
    }

    private func semanticDissimilarity(units: [Unit], boundary: Int) -> Double {
        let leftStart = max(0, boundary - 3)
        let rightEnd = min(units.count, boundary + 3)
        let left = units[leftStart..<boundary].map(\.text).joined(separator: " ")
        let right = units[boundary..<rightEnd].map(\.text).joined(separator: " ")
        guard let a = vectorProvider(left), let b = vectorProvider(right), a.count == b.count, !a.isEmpty else {
            return lexicalDissimilarity(left, right)
        }
        let dot = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
        let normA = sqrt(a.reduce(0.0) { $0 + $1 * $1 })
        let normB = sqrt(b.reduce(0.0) { $0 + $1 * $1 })
        guard normA > 0, normB > 0 else { return lexicalDissimilarity(left, right) }
        return max(0, min(1, 1 - (dot / (normA * normB))))
    }

    private func lexicalDissimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(words(in: lhs))
        let right = Set(words(in: rhs))
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        return 1 - (Double(left.intersection(right).count) / Double(union.count))
    }

    private func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
    }

    private static func sentenceVector(_ text: String) -> [Double]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        return embedding.vector(for: text)
    }
}
