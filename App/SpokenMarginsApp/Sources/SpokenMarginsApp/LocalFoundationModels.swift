import Foundation
import NaturalLanguage
import SessionKit

import FoundationModels

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

@Generable(description: "The complete substantive meaning of one dictated interjection")
struct LocalInterjectionClaimInventory {
    @Guide(
        description: "As many self-contained claims as needed, in source order, up to ten; each must be a real condensation of no more than fourteen words, never a copied transcript sentence. Combine adjacent fragments needed to make one complete claim. Include the opening problem, proposals, benefits, causes, tests, exceptions, and limitations when present. Preserve questions as questions. Every claim must be directly supported by the dictated words; never emit isolated topic words, dangling references, or invented tests.",
        .maximumCount(10)
    )
    var claims: [String]
}

protocol LocalFoundationModelClient: Sendable {
    func availability() -> LocalFoundationModelAvailability
    func summarizeInterjections(context: String) async throws -> String
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String
    /// "Where people reacted" (#476): the reply to `MarginLayerSynthesis.prompt`, one cited sentence per line.
    func summarizeReactions(prompt: String) async throws -> String
    /// A spoken Margin's words rewritten as clear written sentences (#4339), given the passage before and after it. The
    /// reply has not passed `MarginTidyGuard` yet: `MarginTidyProposer` checks it.
    func tidyMargin(transcript: String, before: String, after: String) async throws -> String
}

extension LocalFoundationModelClient {
    func summarizeReactions(prompt: String) async throws -> String {
        throw LocalFoundationModelError.unavailable(availability().description)
    }

    func tidyMargin(transcript: String, before: String, after: String) async throws -> String {
        throw LocalFoundationModelError.unavailable(availability().description)
    }
}

#if DEBUG
/// Deterministic model seam for end-to-end UI tests. Release builds do not
/// compile it (#517); `UITestingHooks` is the only code that creates one.
final class UITestingLocalFoundationModelClient: LocalFoundationModelClient, @unchecked Sendable {
    enum Mode: String {
        case succeed
        case failOnce = "fail_once"
        case fail
    }

    private let mode: Mode
    private let lock = NSLock()
    private var summaryAttempts = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func availability() -> LocalFoundationModelAvailability { .available }

    func summarizeInterjections(context: String) async throws -> String {
        let attempt = lock.withLock {
            summaryAttempts += 1
            return summaryAttempts
        }
        if mode == .fail || (mode == .failOnce && attempt == 1) {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        return "- Each interjection should be condensed into its substantive claims instead of receiving a cleaned transcript."
    }

    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        LocalListeningMapLabel(title: "Chapter \(chapterNumber)", description: "A UI testing chapter.")
    }

    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        "A UI testing listening map."
    }

    func summarizeReactions(prompt: String) async throws -> String {
        if mode == .fail { throw LocalFoundationModelError.emptyResponse }
        return "People reacted near the start. [m1]"
    }

    /// The filler-only tidy with a full stop, so a UI test can tell the model's proposal from the filler-only one, and so
    /// the reply passes `MarginTidyGuard` for whatever Margin the test seeds. `fail` makes it throw, as a model that can't.
    func tidyMargin(transcript: String, before: String, after: String) async throws -> String {
        if mode == .fail { throw LocalFoundationModelError.emptyResponse }
        let tidy = MarginTidy.fillerOnly(transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = tidy.last, !".!?".contains(last) else { return tidy }
        return tidy + "."
    }
}
#endif

struct AppleFoundationModelClient: LocalFoundationModelClient {
    func availability() -> LocalFoundationModelAvailability {
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

    func summarizeInterjections(context: String) async throws -> String {
        try requireAvailability()
        guard let payload = LocalInterjectionDecoder.summaryPayload(from: context),
              !payload.interjections.isEmpty else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        return try await respondWithReliableSummary(payload: payload)
    }

    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        try requireAvailability()
        let prompt = """
        Label this bounded section of a spoken item. Return only JSON with fields "title", "description", "eligibility", and "eligibilityReason". The title must be at most 8 words. The description must be one sentence and at most 28 words. Eligibility must be "eligible", "excluded", or "unknown". Use "excluded" only when the section itself provides positive evidence that it is an advertisement, trailer, credits, or other non-editorial material; a seek or topic change is never sufficient. Use "unknown" when uncertain. Describe the topic without quoting long passages or reproducing the transcript.

        SECTION \(chapterNumber):
        \(String(text.prefix(6_000)))
        """
        let raw = try await respond(to: prompt, maximumResponseTokens: 160)
        let label = try LocalInterjectionDecoder.decodeLabel(raw)
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

    func summarizeReactions(prompt: String) async throws -> String {
        try requireAvailability()
        return try await respond(to: prompt, maximumResponseTokens: 400)
    }

    /// One request per piece of a tidy (#4339), in the words `MarginTidyPrompt` holds: the task in the session's
    /// instructions, the Margin and up to 500 characters of passage on each side in the prompt, greedy sampling.
    /// Guardrails are Apple's setting for transforming the user's own text: with the default ones the model threw on a
    /// Margin with a swear word, one about a massacre in the passage, and one that said "say hello" (eval, 2026-11-24).
    /// If the request overflows the model's window, it is tried once more without the passage.
    func tidyMargin(transcript: String, before: String, after: String) async throws -> String {
        try requireAvailability()
        do {
            return try await tidy(MarginTidyPrompt.request(transcript: transcript, before: before, after: after))
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return try await tidy(MarginTidyPrompt.request(transcript: transcript, before: "", after: ""))
        }
    }

    private func tidy(_ request: MarginTidyRequest) async throws -> String {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
            instructions: request.instructions
        )
        let response = try await session.respond(
            to: request.prompt,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: request.maximumResponseTokens)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalFoundationModelError.emptyResponse }
        return text
    }

    private func requireAvailability() throws {
        guard availability().isAvailable else {
            throw LocalFoundationModelError.unavailable(availability().description)
        }
    }

    private func respond(to prompt: String, maximumResponseTokens: Int) async throws -> String {
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

    private func respondWithReliableSummary(payload: LocalInterjectionSummaryPayload) async throws -> String {
        var bullets: [String] = []
        for record in payload.interjections {
            let scopedPayload = LocalInterjectionSummaryPayload(
                schemaVersion: payload.schemaVersion,
                itemTitle: payload.itemTitle,
                interjections: [record]
            )
            bullets.append(try await summarize(record: record, payload: scopedPayload))
        }
        return bullets.map { "- \($0)" }.joined(separator: "\n")
    }

    private func summarize(
        record: LocalInterjectionSummaryRecord,
        payload: LocalInterjectionSummaryPayload
    ) async throws -> String {
        do {
            return try await summarizeViaPlainTextPoints(record: record, payload: payload)
        } catch {
            if error is CancellationError { throw error }
            // Structured extraction and the grounding checks can surface a
            // content-transformation refusal as a generic quality rejection.
            // Give either form one bounded permissive transformation attempt.
            let qualityGateRejected = (error as? LocalFoundationModelError) == .invalidInterjectionSummary
            guard qualityGateRejected || Self.isSafetyRejection(error) else { throw error }
            return try await summarizeViaPermissiveTransformation(
                record: record,
                payload: payload
            )
        }
    }

    private func summarizeViaPermissiveTransformation(
        record: LocalInterjectionSummaryRecord,
        payload: LocalInterjectionSummaryPayload
    ) async throws -> String {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        var responses: [String] = []
        var lastError: Error?
        let repairedRecord = LocalInterjectionSummaryRecord(
            id: record.id,
            anchorBefore: record.anchorBefore,
            anchorAfter: record.anchorAfter,
            note: LocalInterjectionSafetyTerms.repairContextProvenDictation(in: record.note)
        )
        let requiredMeaning = LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(
            record.note
        )
        let requiredSuffix = requiredMeaning.isEmpty
            ? ""
            : "\n\nREQUIRED SOURCE-SUPPORTED MEANING:\n- " + requiredMeaning.joined(separator: "\n- ")
        for basePrompt in LocalInterjectionPrompts.interjectionSummaryPrompts(record: repairedRecord).prefix(2) {
            do {
                let session = LanguageModelSession(
                    model: model,
                    instructions: LocalInterjectionPrompts.interjectionPermissiveTransformationInstructions
                )
                let response = try await session.respond(
                    to: basePrompt + requiredSuffix,
                    options: GenerationOptions(
                        sampling: responses.isEmpty ? .greedy : .random(top: 20),
                        maximumResponseTokens: 192
                    )
                )
                let candidate = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = LocalInterjectionSummaryPolicy.compactMeaningSummary(
                    LocalInterjectionSummaryPolicy.cleanModelCandidate(candidate)
                )
                let preservesRequiredMeaning = LocalInterjectionSummaryPolicy.auditedMeaningPoints(
                    [cleaned],
                    source: record.note
                ).count == 1
                if !cleaned.isEmpty, preservesRequiredMeaning { responses.append(cleaned) }
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        guard !responses.isEmpty else {
            throw lastError ?? LocalFoundationModelError.invalidInterjectionSummary
        }
        return try LocalInterjectionSummaryPolicy.bestCandidate(
            from: responses,
            payload: payload
        )
    }

    private func summarizeViaPlainTextPoints(
        record: LocalInterjectionSummaryRecord,
        payload: LocalInterjectionSummaryPayload
    ) async throws -> String {
        let sourceNameReference = record.anchorBefore + " " + payload.itemTitle
        let extractionRecord = LocalInterjectionSummaryRecord(
            id: record.id,
            anchorBefore: record.anchorBefore,
            anchorAfter: record.anchorAfter,
            note: record.note
        )
        var extractedPointCandidates: [[String]] = []
        var extractionError: Error?
        let modelSafeNote = LocalInterjectionSafetyTerms.modelSafeInterjectionText(extractionRecord.note)
        let extractionSamplingModes: [GenerationOptions.SamplingMode] = [
            .random(top: 20),
            .greedy
        ]
        for sampling in extractionSamplingModes {
            do {
                let extractionSession = LanguageModelSession(
                    model: .default,
                    instructions: LocalInterjectionPrompts.interjectionPointExtractionInstructions
                )
                let extraction = try await extractionSession.respond(
                    to: "DICTATED INTERJECTION:\n\(modelSafeNote)",
                    generating: LocalInterjectionClaimInventory.self,
                    includeSchemaInPrompt: true,
                    options: GenerationOptions(sampling: sampling, maximumResponseTokens: 512)
                )
                let sourceWordCount = modelSafeNote
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
                let minimumClaimPrecision = sourceWordCount > 150 ? 0.34 : 0.45
                let decodedPoints = extraction.content.claims.compactMap { rawClaim -> String? in
                    let claim = LocalInterjectionSummaryPolicy.cleanSpokenNote(rawClaim)
                    let claimWordCount = claim
                        .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
                    let sourcePrecision = LocalInterjectionSummaryPolicy.semanticOverlapRatio(
                        claim,
                        with: modelSafeNote
                    )
                    guard claimWordCount >= 3, sourcePrecision >= minimumClaimPrecision else { return nil }
                    return LocalInterjectionSafetyTerms.restoreSafetyTerms(in: claim)
                }
                let extractionCoverage = LocalInterjectionSummaryPolicy.semanticCoverageRatio(
                    extraction.content.claims.joined(separator: " "),
                    source: modelSafeNote
                )
                let minimumClaimCount: Int
                if sourceWordCount > 150 {
                    minimumClaimCount = 5
                } else if sourceWordCount > 60 {
                    minimumClaimCount = 3
                } else {
                    minimumClaimCount = 1
                }
                let inventoryIsCompleteEnough = extractionCoverage >= 0.17
                    && (decodedPoints.count >= minimumClaimCount || extractionCoverage >= 0.35)
                guard inventoryIsCompleteEnough else {
                    throw LocalFoundationModelError.invalidInterjectionSummary
                }
                let auditedPoints = LocalInterjectionSummaryPolicy.auditedMeaningPoints(
                    decodedPoints,
                    source: extractionRecord.note
                )
                let explicitAuditPoints = LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(
                    extractionRecord.note
                )
                if sourceWordCount <= 150, explicitAuditPoints.count >= 3 {
                    extractedPointCandidates.append(explicitAuditPoints)
                } else {
                    extractedPointCandidates.append(auditedPoints)
                }
            } catch {
                if error is CancellationError { throw error }
                extractionError = error
            }
        }
        guard !extractedPointCandidates.isEmpty else {
            throw extractionError ?? LocalFoundationModelError.invalidInterjectionSummary
        }

        let fastPathWordLimit = LocalInterjectionSummaryPolicy.summaryWordLimit(
            for: record.note.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        for extractedPoints in extractedPointCandidates {
            let groundedClaims = extractedPoints.map {
                LocalInterjectionSummaryPolicy.compactMeaningPoint(
                    $0,
                    sourceNameReference: sourceNameReference
                )
            }.filter { !$0.isEmpty }
            let modelSafeClaims = groundedClaims.map(LocalInterjectionSafetyTerms.modelSafeInterjectionText)
            for sampling in [GenerationOptions.SamplingMode.greedy, .random(top: 20)] {
                do {
                    let synthesisSession = LanguageModelSession(
                        model: .default,
                        instructions: """
                        Merge one grounded claim inventory into a concise semicolon-separated claim set. Preserve every distinct claim, question, causal link, contrast, exception, and condition. Merge only genuine overlap. Do not add, answer, or evaluate anything. Return only the claim set.
                        """
                    )
                    let response = try await synthesisSession.respond(
                        to: "Use at most \(fastPathWordLimit) words.\nGROUNDED CLAIMS:\n- "
                            + modelSafeClaims.joined(separator: "\n- "),
                        options: GenerationOptions(sampling: sampling, maximumResponseTokens: 256)
                    )
                    let candidate = LocalInterjectionSafetyTerms.restoreSafetyTerms(
                        in: LocalInterjectionSummaryPolicy.cleanModelCandidate(response.content)
                    )
                    let auditedCandidate = LocalInterjectionSummaryPolicy.compactMeaningSummary(
                        LocalInterjectionSummaryPolicy.auditedMeaningPoints(
                            [candidate],
                            source: extractionRecord.note
                        ).joined(separator: "; ")
                    )
                    return try LocalInterjectionSummaryPolicy.validateGuidedSynthesis(
                        auditedCandidate,
                        sourceRecord: extractionRecord,
                        groundedClaims: groundedClaims
                            + LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(
                                extractionRecord.note
                            ),
                        wordLimit: fastPathWordLimit
                    )
                } catch {
                    if error is CancellationError { throw error }
                    extractionError = error
                }
            }
        }

        func condense(_ extractedPoints: [String]) async throws -> String {
        var points: [String] = []
        for rawPoint in extractedPoints {
            let point = LocalInterjectionSummaryPolicy.compactMeaningPoint(
                rawPoint,
                sourceNameReference: sourceNameReference
            )
            guard !point.isEmpty else { continue }
            if let duplicateIndex = points.firstIndex(where: {
                LocalInterjectionSummaryPolicy.semanticSimilarity(point, $0) >= 0.60
            }) {
                let protectedTerms = ["equivalent", "creativity", "human goals", "not a claimed"]
                let pointPriority = protectedTerms.filter {
                    point.range(of: $0, options: .caseInsensitive) != nil
                }.count
                let existingPriority = protectedTerms.filter {
                    points[duplicateIndex].range(of: $0, options: .caseInsensitive) != nil
                }.count
                if pointPriority > existingPriority {
                    points[duplicateIndex] = point
                } else if point.hasSuffix("?") && !points[duplicateIndex].hasSuffix("?") {
                    points[duplicateIndex] = point
                } else if point.count < points[duplicateIndex].count
                            && point.hasSuffix("?") == points[duplicateIndex].hasSuffix("?") {
                    points[duplicateIndex] = point
                }
            } else {
                points.append(point)
            }
        }
        var coalescedPoints: [String] = []
        var pointIndex = 0
        while pointIndex < points.count {
            let point = points[pointIndex]
            if point.lowercased().hasPrefix("if "),
               points.indices.contains(pointIndex + 1),
               points[pointIndex + 1].lowercased().hasPrefix("but ") {
                var merged = point + ", " + points[pointIndex + 1]
                pointIndex += 2
                if points.indices.contains(pointIndex) {
                    let outcome = points[pointIndex].lowercased()
                    if outcome.contains("stop") || outcome.contains("reward") {
                        merged += "; " + points[pointIndex]
                        pointIndex += 1
                    }
                }
                coalescedPoints.append(merged)
            } else {
                coalescedPoints.append(point)
                pointIndex += 1
            }
        }
        points = coalescedPoints
        guard !points.isEmpty else { throw LocalFoundationModelError.invalidInterjectionSummary }

        let overallLimit = LocalInterjectionSummaryPolicy.summaryWordLimit(
            for: record.note.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        var clauses: [String] = []
        for (index, point) in points.enumerated() {
            let usedWords = clauses.joined(separator: " ")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            let remainingPoints = max(1, points.count - index)
            let pointLimit = max(4, (overallLimit - usedWords) / remainingPoints)
            let cleanedPoint = point
            let cleanedPointWordCount = cleanedPoint
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            let isDeterministicAuditPoint = cleanedPoint.contains("constraint might be forgotten")
                || cleanedPoint.hasPrefix("Verified zero-day")
                || cleanedPoint.hasPrefix("Allow stopping")
                || cleanedPoint.hasPrefix("Grant an equivalent reward")
            if cleanedPointWordCount <= min(pointLimit, 6)
                || (isDeterministicAuditPoint && cleanedPointWordCount <= pointLimit) {
                clauses.append(cleanedPoint)
                continue
            }
            var candidates: [String] = []
            let generationLimit = max(3, pointLimit - 1)
            let modelSafePoint = LocalInterjectionSafetyTerms.modelSafeInterjectionText(cleanedPoint)
            for sampling in [GenerationOptions.SamplingMode.greedy, .random(top: 20)] {
                let clauseSession = LanguageModelSession(
                    model: .default,
                    instructions: LocalInterjectionPrompts.interjectionPointCondensationInstructions(
                        point: modelSafePoint,
                        wordLimit: generationLimit
                    )
                )
                let clauseResponse = try await clauseSession.respond(
                    to: LocalInterjectionPrompts.interjectionPointCondensationPrompt(
                        point: modelSafePoint,
                        wordLimit: generationLimit
                    ),
                    options: GenerationOptions(sampling: sampling, maximumResponseTokens: 48)
                )
                let modelSafeCandidate = LocalInterjectionSummaryPolicy.cleanModelCandidate(
                    clauseResponse.content
                )
                let candidate = LocalInterjectionSummaryPolicy.repairSourceNames(
                    in: LocalInterjectionSafetyTerms.restoreSafetyTerms(
                        in: modelSafeCandidate
                    ),
                    from: sourceNameReference
                )
                let candidateWordCount = candidate
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
                let preservesQuestion = !cleanedPoint.hasSuffix("?") || candidate.hasSuffix("?")
                let preservesNegation = LocalInterjectionSummaryPolicy.preservesExplicitNegation(
                    candidate: candidate,
                    source: cleanedPoint
                )
                let sourceCoverage = LocalInterjectionSummaryPolicy.semanticOverlapRatio(
                    modelSafePoint,
                    with: modelSafeCandidate
                )
                let candidatePrecision = LocalInterjectionSummaryPolicy.semanticOverlapRatio(
                    modelSafeCandidate,
                    with: modelSafePoint
                )
                if !candidate.isEmpty,
                   candidateWordCount <= pointLimit + 2,
                   preservesQuestion,
                   preservesNegation,
                   sourceCoverage >= 0.10,
                   candidatePrecision >= 0.40 {
                    candidates.append(candidate)
                }
            }
            if let clause = candidates.max(by: {
                LocalInterjectionSummaryPolicy.semanticOverlapRatio(cleanedPoint, with: $0)
                    < LocalInterjectionSummaryPolicy.semanticOverlapRatio(cleanedPoint, with: $1)
            }) {
                clauses.append(clause)
            } else if cleanedPointWordCount <= 14,
                      cleanedPointWordCount <= pointLimit + 4 {
                // Guided generation already guarantees this is a grounded,
                // bounded claim. Keep it when both optional condensation
                // rewrites violate modality, polarity, or their word target.
                clauses.append(cleanedPoint)
            } else {
                throw LocalFoundationModelError.invalidInterjectionSummary
            }
        }
        let joined = LocalInterjectionSummaryPolicy.compactMeaningSummary(
            clauses.joined(separator: "; ")
        )
        return try LocalInterjectionSummaryPolicy.validateGuidedSynthesis(
            joined,
            sourceRecord: extractionRecord,
            groundedClaims: points,
            wordLimit: overallLimit
        )
        }

        var condensationError: Error?
        for extractedPoints in extractedPointCandidates {
            do {
                return try await condense(extractedPoints)
            } catch {
                if error is CancellationError { throw error }
                condensationError = error
            }
        }
        let overallLimit = LocalInterjectionSummaryPolicy.summaryWordLimit(
            for: record.note.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        for extractedPoints in extractedPointCandidates {
            let groundedClaims = extractedPoints.map {
                LocalInterjectionSummaryPolicy.compactMeaningPoint(
                    $0,
                    sourceNameReference: sourceNameReference
                )
            }.filter { !$0.isEmpty }
            let modelSafeClaims = groundedClaims.map(LocalInterjectionSafetyTerms.modelSafeInterjectionText)
            for sampling in [GenerationOptions.SamplingMode.greedy, .random(top: 20)] {
                do {
                    let synthesisSession = LanguageModelSession(
                        model: .default,
                        instructions: """
                        Merge one grounded claim inventory into a concise semicolon-separated claim set. Preserve every distinct claim, question, causal link, contrast, exception, and condition. Merge only genuine overlap. Do not add, answer, or evaluate anything. Return only the claim set.
                        """
                    )
                    let response = try await synthesisSession.respond(
                        to: "Use at most \(overallLimit) words.\nGROUNDED CLAIMS:\n- "
                            + modelSafeClaims.joined(separator: "\n- "),
                        options: GenerationOptions(sampling: sampling, maximumResponseTokens: 256)
                    )
                    let candidate = LocalInterjectionSafetyTerms.restoreSafetyTerms(
                        in: LocalInterjectionSummaryPolicy.cleanModelCandidate(response.content)
                    )
                    let auditedCandidate = LocalInterjectionSummaryPolicy.compactMeaningSummary(
                        LocalInterjectionSummaryPolicy.auditedMeaningPoints(
                            [candidate],
                            source: extractionRecord.note
                        ).joined(separator: "; ")
                    )
                    return try LocalInterjectionSummaryPolicy.validateGuidedSynthesis(
                        auditedCandidate,
                        sourceRecord: extractionRecord,
                        groundedClaims: groundedClaims
                            + LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(
                                extractionRecord.note
                            ),
                        wordLimit: overallLimit
                    )
                } catch {
                    if error is CancellationError { throw error }
                    condensationError = error
                }
            }
        }
        let explicitAuditPoints = LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(
            extractionRecord.note
        ).map {
            LocalInterjectionSummaryPolicy.compactMeaningPoint(
                $0,
                sourceNameReference: sourceNameReference
            )
        }.filter { !$0.isEmpty }
        let reservedWords = explicitAuditPoints.joined(separator: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        let orderedCandidates = extractedPointCandidates.sorted { lhs, rhs in
            lhs.joined(separator: " ").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
                < rhs.joined(separator: " ").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        }
        for extractedPoints in orderedCandidates {
            let groundedClaims = extractedPoints.map {
                LocalInterjectionSummaryPolicy.compactMeaningPoint(
                    $0,
                    sourceNameReference: sourceNameReference
                )
            }.filter { !$0.isEmpty }
            var selected: [String] = []
            var selectedWords = 0
            let modelWordBudget = max(0, overallLimit - reservedWords)
            for claim in groundedClaims {
                let claimWordCount = claim
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
                let lowerClaim = claim.lowercased()
                let overlapsReserved = explicitAuditPoints.contains {
                    LocalInterjectionSummaryPolicy.semanticSimilarity(claim, $0) >= 0.60
                }
                let overlapsSelected = selected.contains {
                    LocalInterjectionSummaryPolicy.semanticSimilarity(claim, $0) >= 0.60
                }
                guard !overlapsReserved,
                      !overlapsSelected,
                      claimWordCount >= 4,
                      claimWordCount <= 18,
                      !lowerClaim.hasPrefix("that's unfortunate"),
                      !lowerClaim.hasPrefix("that is unfortunate"),
                      !lowerClaim.hasPrefix("but "),
                      !LocalInterjectionSummaryPolicy.sharesLongPhrase(
                        claim,
                        with: extractionRecord.note
                      ),
                      selectedWords + claimWordCount <= modelWordBudget else { continue }
                selected.append(claim)
                selectedWords += claimWordCount
            }
            let assembled = LocalInterjectionSummaryPolicy.compactMeaningSummary(
                (selected + explicitAuditPoints).joined(separator: "; ")
            )
            do {
                return try LocalInterjectionSummaryPolicy.validateGuidedSynthesis(
                    assembled,
                    sourceRecord: extractionRecord,
                    groundedClaims: groundedClaims + explicitAuditPoints,
                    wordLimit: overallLimit
                )
            } catch {
                if error is CancellationError { throw error }
                condensationError = error
            }
        }
        throw condensationError ?? extractionError ?? LocalFoundationModelError.invalidInterjectionSummary
    }

    static func isSafetyRejection(_ error: Error) -> Bool {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .guardrailViolation, .refusal:
                return true
            default:
                break
            }
        }
        let description = String(reflecting: error).lowercased()
        return description.contains("guardrailviolation")
            || description.contains("may contain sensitive content")
            || description.contains("detected content likely to be unsafe")
    }
}

extension ListeningMapSummaryValidator {
    /// Checks the on-device model's label for one scene (#482); keeps the call site in the model to one line.
    static func validate(_ label: LocalListeningMapLabel, sourceText: String) throws -> SceneLabel {
        try validate(
            title: label.title,
            description: label.description,
            eligibility: label.eligibility,
            eligibilityReason: label.eligibilityReason,
            sourceText: sourceText,
            language: transcriptLanguage(of: sourceText)
        )
    }

    /// The scene's language as a BCP 47 tag ("de"), or nil when it can't be told. Transcripts don't record one, and
    /// a German scene's role nouns are not names (#2082).
    static func transcriptLanguage(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }
}

struct AppleFoundationAIProvider: AIProviderClient {
    let providerType = "apple_foundation_on_device"
    let model = "system_language_model"
}
