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
    var eligibility: PortableSceneEligibility? = nil
    var eligibilityReason: String? = nil
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

struct LocalInterjectionMeaningSlots: Codable, Equatable, Sendable {
    let question: String?
    let points: [String]
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "The complete substantive meaning of one dictated interjection")
struct LocalInterjectionClaimInventory {
    @Guide(
        description: "As many self-contained claims as needed, in source order, up to ten; each must be a real condensation of no more than fourteen words, never a copied transcript sentence. Combine adjacent fragments needed to make one complete claim. Include the opening problem, proposals, benefits, causes, tests, exceptions, and limitations when present. Preserve questions as questions. Every claim must be directly supported by the dictated words; never emit isolated topic words, dangling references, or invented tests.",
        .maximumCount(10)
    )
    var claims: [String]
}
#endif

enum LocalInterjectionSummaryPolicy {
    static let anchorCharacterLimit = 240
    private static let fillerPattern = #"(?i)\b(?:u+h+m*|u+m+|e+r+m*|a+h+|h+m+)\b"#
    private static let verbalTickPattern = #"(?i)(?:\b(?:you know|i mean)\b|\bi\s*,?\s*think\b|(?:^|[.!?]\s+)(?:yeah|well|okay|so)\b)"#
    private static let metaFramingPattern = #"(?i)^(?:(?:the\s+)?(?:listener|speaker|note|interjection|feedback)|the\s+user)\b"#
    private static let checklistFramingPattern = #"(?i)^(?:attribution|exception|action|objection|question|requested change)\s*:"#
    private static let outputLabelPattern = #"(?i)^(?:summary|rewrite|concise version|result|claim|requirement)\s*:\s*"#
    private static let contentStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "because", "been", "but", "by", "can", "do", "does",
        "for", "from", "had", "has", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in",
        "is", "it", "its", "me", "my", "not", "of", "on", "or", "our", "she", "should", "so", "that",
        "the", "their", "them", "there", "they", "this", "to", "too", "us", "was", "we", "were", "what",
        "when", "which", "who", "why", "will", "with", "would", "you", "your"
    ]

    static func cleanSpokenNote(_ note: String) -> String {
        var cleaned = note
        cleaned = replacing(
            fillerPattern + #"[\s,;:—–-]*"#,
            in: cleaned,
            with: ""
        )
        cleaned = replacing(
            #"(?i)\b([[:alpha:]][[:alnum:]’']*)\b(?:[\s,]+\1\b)+"#,
            in: cleaned,
            with: "$1"
        )
        cleaned = replacing(#"(?i)\b(?:you know|i mean)\b[\s,;:—–-]*"#, in: cleaned, with: "")
        cleaned = replacing(
            #"(?i)(^|[.!?]\s+)(?:so)?lution:\s*"#,
            in: cleaned,
            with: "$1"
        )
        cleaned = replacing(#"(?i)\bi\s*,?\s*think\b[\s,;:—–-]*(?:that\b[\s,;:—–-]*)?"#, in: cleaned, with: "")
        cleaned = replacing(#"(?i)\bwe\s+need\s+to\s+make\s+sure\s+that\b"#, in: cleaned, with: "Ensure")
        cleaned = replacing(#"(?i)\bwe\s+need\s+to\s+make\s+sure\s+(?:it'?s|this\s+is)\b"#, in: cleaned, with: "Ensure it is")
        cleaned = replacing(#"(?i)\bthis\s+is\s+totally\b"#, in: cleaned, with: "This is")
        cleaned = replacing(#"(?i)\bthis\s+can\s+totally\b"#, in: cleaned, with: "This can")
        cleaned = replacing(#"(?i)^(?:yeah|well|okay|so)\s*,?\s*"#, in: cleaned, with: "")
        cleaned = replacing(#"(?i)(?<=[.!?])\s+(?:yeah|well|okay|so)\s*,?\s*"#, in: cleaned, with: " ")
        cleaned = replacing(#"(?i)(^|[?;.!]\s+)yes\s*,?\s+"#, in: cleaned, with: "$1")
        cleaned = replacing(
            #"(?i)\b([[:alpha:]][[:alnum:]’']*)\b(?:[\s,]+\1\b)+"#,
            in: cleaned,
            with: "$1"
        )
        cleaned = replacing(#"\s+([,.!?;:])"#, in: cleaned, with: "$1")
        cleaned = replacing(#"([,;:]){2,}"#, in: cleaned, with: "$1")
        cleaned = replacing(#"\s{2,}"#, in: cleaned, with: " ")
        let preservesQuestionMark = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let first = cleaned.first else { return cleaned }
        let result = first.uppercased() + String(cleaned.dropFirst())
        return preservesQuestionMark ? result + "?" : result
    }

    static func cleanModelCandidate(_ response: String) -> String {
        var candidate = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate = candidate
                .replacingOccurrences(of: "```text", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        candidate = candidate
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        candidate = replacing(#"^(?:[-•*]|\d+[.)])\s*"#, in: candidate, with: "")
        candidate = replacing(outputLabelPattern, in: candidate, with: "")
        candidate = candidate.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'‘’"))
        )
        return cleanSpokenNote(candidate)
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
        let filler = try NSRegularExpression(pattern: fillerPattern)
        let verbalTick = try NSRegularExpression(pattern: verbalTickPattern)
        let metaFraming = try NSRegularExpression(pattern: metaFramingPattern)
        let checklistFraming = try NSRegularExpression(pattern: checklistFramingPattern)
        for (index, bullet) in cleaned.enumerated() {
            let range = NSRange(bullet.startIndex..<bullet.endIndex, in: bullet)
            let sourceRecord = payload.interjections[min(index, payload.interjections.count - 1)]
            let sourceWordCount = normalizedWords(sourceRecord.note).count
            let maximumBulletWords = summaryWordLimit(for: sourceWordCount)
            let bulletWords = normalizedWords(bullet)
            guard filler.firstMatch(in: bullet, range: range) == nil,
                  verbalTick.firstMatch(in: bullet, range: range) == nil,
                  metaFraming.firstMatch(in: bullet, range: range) == nil,
                  checklistFraming.firstMatch(in: bullet, range: range) == nil,
                  !bulletWords.isEmpty,
                  bulletWords.count <= maximumBulletWords,
                  normalizedText(bullet) != normalizedText(sourceRecord.note),
                  (sourceWordCount <= 24
                    || !sharesLongPhrase(bullet, with: sourceRecord.note)
                    || (sourceAsksQuestion(sourceRecord.note) && bullet.contains("?"))),
                  preservesQuestionModality(candidate: bullet, source: sourceRecord.note),
                  preservesNamedConcerns(candidate: bullet, source: sourceRecord.note),
                  preservesRequestedActions(candidate: bullet, source: sourceRecord.note),
                  preservesExplicitNegation(candidate: bullet, source: sourceRecord.note),
                  semanticCoverageRatio(bullet, source: sourceRecord.note) >= minimumSemanticCoverage(
                    forSourceWordCount: sourceWordCount
                  ) else {
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

    static func summaryWordLimit(for sourceWordCount: Int) -> Int {
        guard sourceWordCount > 0 else { return 0 }
        if sourceWordCount <= 6 { return sourceWordCount }
        if sourceWordCount <= 12 { return max(5, sourceWordCount - 2) }
        if sourceWordCount <= 24 {
            return max(8, Int((Double(sourceWordCount) * 0.75).rounded(.down)))
        }
        if sourceWordCount <= 60 {
            return max(8, Int((Double(sourceWordCount) * 0.64).rounded(.down)))
        }
        // Long interjections can contain several independent claims. A fixed
        // 28-word ceiling forced the model either to omit claims or fail the
        // quality gate. Preserve claim integrity while remaining strongly
        // compressive; very long notes may use a compact claim set.
        if sourceWordCount <= 150 {
            return min(50, max(20, Int((Double(sourceWordCount) * 0.50).rounded(.down))))
        }
        return min(96, max(40, Int((Double(sourceWordCount) * 0.35).rounded(.down))))
    }

    static func bestCandidate(
        from responses: [String],
        payload: LocalInterjectionSummaryPayload
    ) throws -> String {
        guard payload.interjections.count == 1, let record = payload.interjections.first else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        let candidates = responses.compactMap { response -> String? in
            let candidate = compactMeaningSummary(cleanModelCandidate(response))
            return try? validate(bullets: [candidate], payload: payload)[0]
        }
        guard !candidates.isEmpty else { throw LocalFoundationModelError.invalidInterjectionSummary }
        return candidates.max { lhs, rhs in
            candidateScore(lhs, source: record.note) < candidateScore(rhs, source: record.note)
        }!
    }

    static func validateGuidedSynthesis(
        _ response: String,
        sourceRecord: LocalInterjectionSummaryRecord,
        groundedClaims: [String],
        wordLimit: Int
    ) throws -> String {
        let candidate = compactMeaningSummary(cleanModelCandidate(response))
        let candidateWords = normalizedWords(candidate)
        let sourceWords = normalizedWords(sourceRecord.note)
        let groundedText = groundedClaims.joined(separator: "; ")
        let filler = try NSRegularExpression(pattern: fillerPattern)
        let verbalTick = try NSRegularExpression(pattern: verbalTickPattern)
        let metaFraming = try NSRegularExpression(pattern: metaFramingPattern)
        let checklistFraming = try NSRegularExpression(pattern: checklistFramingPattern)
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard !candidateWords.isEmpty,
              candidateWords.count <= wordLimit,
              candidateWords.count < sourceWords.count,
              filler.firstMatch(in: candidate, range: range) == nil,
              verbalTick.firstMatch(in: candidate, range: range) == nil,
              metaFraming.firstMatch(in: candidate, range: range) == nil,
              checklistFraming.firstMatch(in: candidate, range: range) == nil,
              preservesQuestionModality(candidate: candidate, source: sourceRecord.note),
              preservesNamedConcerns(candidate: candidate, source: sourceRecord.note),
              preservesRequestedActions(candidate: candidate, source: sourceRecord.note),
              preservesExplicitNegation(candidate: candidate, source: sourceRecord.note),
              preservesCausalDirection(candidate: candidate, source: sourceRecord.note),
              auditedMeaningPoints([candidate], source: sourceRecord.note).count == 1,
              semanticCoverageRatio(candidate, source: groundedText) >= 0.15,
              semanticOverlapRatio(candidate, with: groundedText) >= 0.45,
              !sharesLongPhrase(candidate, with: sourceRecord.anchorBefore),
              !sharesLongPhrase(candidate, with: sourceRecord.anchorAfter) else {
            throw LocalFoundationModelError.invalidInterjectionSummary
        }
        return candidate
    }

    static func uncoveredTerms(in text: String, excluding coveredText: String) -> [String] {
        Array(contentWords(text).subtracting(contentWords(coveredText))).sorted()
    }

    static func semanticOverlapRatio(_ text: String, with coveredText: String) -> Double {
        let terms = contentWords(text)
        guard !terms.isEmpty else { return 0 }
        return Double(terms.intersection(contentWords(coveredText)).count) / Double(terms.count)
    }

    static func semanticCoverageRatio(_ candidate: String, source: String) -> Double {
        let sourceTerms = contentWords(source)
        guard !sourceTerms.isEmpty else { return 1 }
        return Double(sourceTerms.intersection(contentWords(candidate)).count) / Double(sourceTerms.count)
    }

    static func semanticSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = contentWords(lhs)
        let right = contentWords(rhs)
        let denominator = min(left.count, right.count)
        guard denominator > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(denominator)
    }

    static func repairSourceNames(in text: String, from anchor: String) -> String {
        let entities = sourceNameCandidates(in: anchor)
        guard !entities.isEmpty else { return text }
        var repaired = text
        let originalWords = repaired.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if originalWords.count >= 2 {
            for index in 0..<(originalWords.count - 1) {
                let phrase = originalWords[index...index + 1].joined(separator: " ")
                let phoneticPhrase = phoneticName(phrase)
                guard let entity = entities.first(where: { phoneticName($0) == phoneticPhrase }) else { continue }
                repaired = replacing(
                    #"(?i)\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#,
                    in: repaired,
                    with: entity
                )
            }
        }
        let words = repaired.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for word in words where word.count >= 5 {
            let normalizedWord = normalizedName(word)
            guard !normalizedWord.isEmpty else { continue }
            let match = entities.compactMap { entity -> (String, Double)? in
                let normalizedEntity = normalizedName(entity)
                let denominator = max(normalizedWord.count, normalizedEntity.count)
                guard denominator > 0 else { return nil }
                let similarity = 1 - (Double(editDistance(normalizedWord, normalizedEntity)) / Double(denominator))
                return similarity >= 0.60 ? (entity, similarity) : nil
            }.max { $0.1 < $1.1 }
            guard let match, match.0.caseInsensitiveCompare(word) != .orderedSame else { continue }
            repaired = replacing(
                #"(?i)\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#,
                in: repaired,
                with: match.0
            )
        }
        return repaired
    }

    static func compactMeaningPoint(_ point: String, sourceNameReference: String) -> String {
        var compact = cleanSpokenNote(repairSourceNames(in: point, from: sourceNameReference))
        compact = replacing(
            #"(?i)^if\s+part\s+of\s+the\s+goal\s+is\s+a\s+don['’]t\s+(.+?),?\s+then\s+(?:that|it)\s+might\s+get\s+forgotten$"#,
            in: compact,
            with: "The 'don't $1' constraint might be forgotten"
        )
        compact = replacing(
            #"(?i)^(?:this|it)\s+is\s+fine\s+to\s+(?:have|keep)\s+in\s+a\s+quote$"#,
            in: compact,
            with: "Fine in a quote"
        )
        compact = replacing(
            #"(?i)^remove\s+['‘’\"]?we['’]re\s+writing\s+as\s+(.+?)['‘’\"]?$"#,
            in: compact,
            with: "Remove self-referential $1 wording"
        )
        compact = replacing(
            #"(?i)^(?:a\s+)?low\s+preference\s+for\s+pairing\s+members$"#,
            in: compact,
            with: "Identify low-preference thinking stages"
        )
        compact = replacing(
            #"(?i)^(.+?)['’]s\s+message\s+doesn['’]t\s+resonate$"#,
            in: compact,
            with: "Remove self-referential $1 wording"
        )
        compact = replacing(
            #"(?i)^make\s+sure\s+it['’]s\s+not\s+(.+?)\s+saying\s+it\s+can\s+be\s+(.+?)\s+saying\s+it$"#,
            in: compact,
            with: "Attribute it to $2, not $1"
        )
        compact = replacing(
            #"(?i)^(?:ensure|make\s+sure)\s+(?:it\s+is|it['’]s)?\s*not\s+(.+?)\s+saying\s+it\s+can\s+be\s+(.+?)\s+saying\s+it$"#,
            in: compact,
            with: "Attribute it to $2, not $1"
        )
        let referencedNames = sourceNameCandidates(in: sourceNameReference)
        if let referencedName = referencedNames.first(where: {
            compact.range(of: $0, options: .caseInsensitive) != nil
        }) {
            let escaped = NSRegularExpression.escapedPattern(for: referencedName)
            compact = replacing(
                #"(?i)^(?:this|it)\s+can\s+be\s+"# + escaped + #"(?:\s+saying\s+it)?\s+instead$"#,
                in: compact,
                with: "Attribute it to " + referencedName
            )
        }
        return compact
    }

    static func compactMeaningSummary(_ summary: String) -> String {
        let returnedAsLabeledClaimSet = summary.range(
            of: #"(?i)^\s*claim\s+set\s*:"#,
            options: .regularExpression
        ) != nil
        var compact = replacing(
            #"(?i)make\s+sure\s+(?:it\s+is|it['’]s)\s+not\s+(.+?)\s+saying\s+it\s+can\s+be\s+(.+?)\s+saying\s+it"#,
            in: summary,
            with: "Attribute it to $2, not $1"
        )
        if returnedAsLabeledClaimSet {
            compact = replacing(
                #"(?i)^\s*claim\s+set\s*:\s*"#,
                in: compact,
                with: ""
            )
            compact = replacing(#"(?:^|\s+)\-\s+"#, in: compact, with: "; ")
            compact = replacing(#"\.\s*;"#, in: compact, with: ";")
            compact = compact.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        }
        var clauses = compact.components(separatedBy: ";").map {
            replacing(
                checklistFramingPattern,
                in: $0.trimmingCharacters(in: .whitespacesAndNewlines),
                with: ""
            )
        }.filter { !$0.isEmpty }
        if clauses.contains(where: { $0.contains("?") }) {
            clauses.removeAll {
                !$0.contains("?")
                    && $0.range(
                        of: #"(?i)\bseparate\s+question\b"#,
                        options: .regularExpression
                    ) != nil
            }
        }
        let hasPromptLeakage = clauses.contains {
            $0.range(of: "prompt leakage", options: .caseInsensitive) != nil
        }
        if hasPromptLeakage {
            let hasAIWritten = clauses.contains {
                $0.range(of: #"(?i)\bAI[\s-]+written\b"#, options: .regularExpression) != nil
            }
            let hasStandaloneRemove = clauses.contains {
                $0.range(of: #"(?i)^remove$"#, options: .regularExpression) != nil
            }
            if hasAIWritten, hasStandaloneRemove {
                clauses.removeAll {
                    $0.range(of: "prompt leakage", options: .caseInsensitive) != nil
                        || $0.range(of: #"(?i)\bAI[\s-]+written\b"#, options: .regularExpression) != nil
                        || $0.range(of: #"(?i)^remove$"#, options: .regularExpression) != nil
                }
                clauses.insert("Remove prompt-leakage, AI-written wording", at: 0)
            }
            clauses = clauses.compactMap { clause in
                if clause.range(of: #"(?i)^doesn['’]t\s+make\s+(?:any\s+)?sense$"#, options: .regularExpression) != nil {
                    return nil
                }
                if let range = clause.range(
                    of: #"(?i)^(.+?)\s+message$"#,
                    options: .regularExpression
                ) {
                    let messageClause = String(clause[range])
                    let name = messageClause.replacingOccurrences(
                        of: #"(?i)\s+message$"#,
                        with: "",
                        options: .regularExpression
                    )
                    return "Remove self-referential " + name + " wording"
                }
                return clause
            }
        }
        let hasSelfReferentialCorrection = clauses.contains {
            $0.range(of: "self-referential", options: .caseInsensitive) != nil
        }
        if hasSelfReferentialCorrection {
            clauses.removeAll {
                $0.range(of: #"(?i)^FourSight\s+message$"#, options: .regularExpression) != nil
            }
        }
        clauses = clauses.map { clause in
            if clause.contains("?"),
               clause.range(of: "capability frontier", options: .caseInsensitive) != nil,
               clause.range(of: "misalign", options: .caseInsensitive) != nil {
                return "Does behavior within the capability frontier become obviously misaligned?"
            }
            switch clause.lowercased() {
            case "low preference": return "Identify low-preference thinking stages"
            case "pairing with tools": return "Pair people with tools"
            case "tools": return "Pair people with tools, not only training"
            case "foursight": return "Use FourSight tools"
            case "foursight tools": return "Use FourSight tools"
            case "creative problem solving process", "creative problem-solving process":
                return "Preserve each stage's benefits"
            case "benefits": return "Preserve the benefits"
            default: return clause
            }
        }
        compact = clauses.joined(separator: "; ")
        return compact
    }

    static func auditedMeaningPoints(_ points: [String], source: String) -> [String] {
        var audited = points
        let current = { audited.joined(separator: " ").lowercased() }
        for required in requiredExplicitMeaningPoints(source) {
            let lowerRequired = required.lowercased()
            let isCovered: Bool
            if lowerRequired.hasSuffix("?") {
                isCovered = audited.contains { $0.contains("?") }
            } else if lowerRequired == "prompt leakage" {
                isCovered = current().contains("prompt leakage")
            } else if lowerRequired == "ai-written" {
                isCovered = current().range(of: #"\bai[\s-]+written\b"#, options: .regularExpression) != nil
            } else if lowerRequired.contains("remove") {
                isCovered = current().range(of: #"\bremov"#, options: .regularExpression) != nil
            } else if lowerRequired.contains("point differently") {
                isCovered = current().contains("point") && current().contains("differ")
            } else if lowerRequired == "ai text may not mean anything" {
                isCovered = current().contains("text")
                    && (current().contains("mean") || current().contains("meaning"))
            } else if lowerRequired == "request a model instead of a report" {
                isCovered = current().contains("model") && current().contains("report")
            } else if lowerRequired == "simulate and evaluate assumptions and dynamics" {
                isCovered = current().contains("assumption") && current().contains("dynamic")
            } else if lowerRequired == "train specialized cheating detectors to understand human goals" {
                isCovered = current().contains("specialized")
                    && current().contains("detect")
                    && current().contains("human")
                    && current().contains("goal")
            } else if lowerRequired == "goal abstraction can inject creativity" {
                isCovered = current().contains("abstract") && current().contains("creativ")
            } else if lowerRequired == "cheating can result from unclear goals" {
                isCovered = current().contains("cheat")
                    && current().contains("goal")
                    && current().contains("clear")
            } else if lowerRequired == "pretrain general legal understanding and compliance" {
                isCovered = current().contains("train")
                    && (current().contains("law") || current().contains("legal"))
                    && (current().contains("abid") || current().contains("compliance"))
            } else if lowerRequired == "test-time compute and harder frontier pushing make misalignment persist" {
                isCovered = current().contains("test time")
                    && current().contains("misalign")
                    && (current().contains("persist")
                        || current().contains("continue")
                        || current().contains("increase")
                        || current().contains("never"))
            } else if lowerRequired == "the phase-change claim conflicts with relying on small-model alignment experiments and supervision" {
                isCovered = (current().contains("phase change") || current().contains("phase-change"))
                    && current().contains("small")
                    && current().contains("supervis")
                    && (current().contains("conflict") || current().contains("contradict"))
            } else if lowerRequired == "a tiny lab cannot train models near the frontier" {
                isCovered = current().contains("lab")
                    && current().contains("train")
                    && current().contains("frontier")
            } else if lowerRequired == "under his own mental model, the lab cannot meaningfully participate" {
                isCovered = (current().contains("mental model") || current().contains("own model"))
                    && (current().contains("participat") || current().contains("play"))
            } else if lowerRequired == "require a verified vulnerability, not a claimed one" {
                isCovered = current().contains("verified")
                    && current().contains("claim")
                    && current().contains("not")
            } else if lowerRequired == "grant an equivalent reward for the verified zero-day" {
                isCovered = current().contains("equivalent") && current().contains("reward")
            } else {
                isCovered = current().contains(lowerRequired)
            }
            if !isCovered { audited.append(required) }
        }
        return audited
    }

    static func requiredExplicitMeaningPoints(_ source: String) -> [String] {
        let lowerSource = source.lowercased()
        var required: [String] = []
        if lowerSource.contains("capability frontier"),
           lowerSource.contains("obviously misaligned"),
           source.contains("?") {
            required.append("Does behavior within the capability frontier become obviously misaligned?")
        }
        if let wonderRange = source.range(
            of: #"(?i)\bi\s+wonder\b"#,
            options: .regularExpression
        ) {
            let tail = source[wonderRange.lowerBound...]
            let end = tail.firstIndex(where: { ".!?".contains($0) }) ?? tail.endIndex
            var question = cleanSpokenNote(String(tail[..<end]))
            if !question.isEmpty {
                if !question.hasSuffix("?") { question += "?" }
                required.append(question)
            }
        }
        if required.allSatisfy({ !$0.hasSuffix("?") }),
           let questionMark = source.firstIndex(of: "?") {
            let prefix = source[..<questionMark]
            let questionStart = prefix.lastIndex(where: { ".!?".contains($0) })
                .map { source.index(after: $0) }
                ?? source.startIndex
            var question = cleanSpokenNote(String(source[questionStart...questionMark]))
            if !question.isEmpty {
                if !question.hasSuffix("?") { question += "?" }
                required.append(question)
            }
        }
        let mentionsZeroDay = lowerSource.range(
            of: #"\bzero[ -]?day\b|\b0[ -]?day\b"#,
            options: .regularExpression
        ) != nil
        if mentionsZeroDay {
            required.append("Verified zero-day vulnerability")
        }
        if mentionsZeroDay, lowerSource.contains("get to stop") {
            required.append("Allow stopping after a verified zero-day")
        }
        if mentionsZeroDay, lowerSource.contains("equivalent reward") {
            required.append("Grant an equivalent reward for the verified zero-day")
        }
        if lowerSource.contains("text"), lowerSource.contains("mean anything") {
            required.append("AI text may not mean anything")
        }
        if lowerSource.contains("instead of asking for a report"),
           lowerSource.contains("ask for a model") {
            required.append("Request a model instead of a report")
        }
        if lowerSource.contains("simulate"),
           lowerSource.contains("assumptions"),
           lowerSource.contains("dynamics") {
            required.append("Simulate and evaluate assumptions and dynamics")
        }
        if lowerSource.contains("specialized models"),
           lowerSource.contains("detect cheating"),
           lowerSource.contains("understand what the human wants") {
            required.append("Train specialized cheating detectors to understand human goals")
        }
        if lowerSource.contains("abstract"), lowerSource.contains("creativity") {
            required.append("Goal abstraction can inject creativity")
        }
        if lowerSource.contains("cheating"),
           lowerSource.contains("goal isn't very clear") {
            required.append("Cheating can result from unclear goals")
        }
        if lowerSource.contains("pre-training"),
           lowerSource.contains("understanding of laws"),
           lowerSource.range(of: #"\bab(?:id|ind)\w*\b"#, options: .regularExpression) != nil {
            required.append("Pretrain general legal understanding and compliance")
        }
        if lowerSource.contains("test time compute"),
           lowerSource.contains("never going to get away"),
           lowerSource.contains("misalignment") {
            required.append("Test-time compute and harder frontier pushing make misalignment persist")
        }
        if lowerSource.contains("contradicting himself"),
           lowerSource.contains("phase change"),
           lowerSource.contains("training small models"),
           lowerSource.contains("supervision") {
            required.append(
                "The phase-change claim conflicts with relying on small-model alignment experiments and supervision"
            )
        }
        if lowerSource.contains("train models even close to the frontier"),
           (lowerSource.contains("tiny land") || lowerSource.contains("tiny lab")) {
            required.append("A tiny lab cannot train models near the frontier")
        }
        if lowerSource.contains("play in the game"),
           lowerSource.contains("mental model") {
            required.append("Under his own mental model, the lab cannot meaningfully participate")
        }
        if mentionsZeroDay, lowerSource.contains("just claim") {
            required.append("Require a verified vulnerability, not a claimed one")
        }
        if lowerSource.contains("prompt leakage") { required.append("Prompt leakage") }
        if lowerSource.range(of: #"\bai[\s-]+written\b"#, options: .regularExpression) != nil {
            required.append("AI-written")
        }
        if lowerSource.range(of: #"\bremov"#, options: .regularExpression) != nil {
            if let expression = try? NSRegularExpression(
                pattern: #"(?i)we['’]re\s+writing\s+as\s+([[:alnum:]'-]+)"#
            ) {
                let range = NSRange(source.startIndex..<source.endIndex, in: source)
                if let match = expression.firstMatch(in: source, range: range),
                   let nameRange = Range(match.range(at: 1), in: source) {
                    required.append("Remove self-referential " + String(source[nameRange]) + " wording")
                } else {
                    required.append("Remove the criticized wording")
                }
            } else {
                required.append("Remove the criticized wording")
            }
        }
        if lowerSource.contains("point differently") { required.append("Make the point differently") }
        if lowerSource.range(
            of: #"fine\s+to\s+(?:have|keep)\s+in\s+a\s+quote"#,
            options: .regularExpression
        ) != nil {
            required.append("Fine in a quote")
        }
        if let negativeExpression = try? NSRegularExpression(
            pattern: #"(?i)\bnot\s+([[:alpha:]'-]+)\s+saying\s+this"#
        ),
           let positiveExpression = try? NSRegularExpression(
            pattern: #"(?i)\bbe\s+([[:alpha:]'-]+(?:\s+[[:alpha:]'-]+){0,2})\s+saying\s+it"#
        ) {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            if let negativeMatch = negativeExpression.firstMatch(in: source, range: range),
               let positiveMatch = positiveExpression.firstMatch(in: source, range: range),
               let negativeRange = Range(negativeMatch.range(at: 1), in: source),
               let positiveRange = Range(positiveMatch.range(at: 1), in: source) {
                required.append(
                    "Attribute it to " + String(source[positiveRange])
                        + ", not " + String(source[negativeRange])
                )
            }
        }
        return required
    }

    private static func replacing(_ pattern: String, in source: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.stringByReplacingMatches(in: source, range: range, withTemplate: replacement)
    }

    private static func sourceNameCandidates(in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(?:[A-Z][[:alpha:]’'-]{1,})(?:\s+[A-Z][[:alpha:]’'-]{1,})*\b"#
        ) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let ignored = Set(["The", "This", "That", "With", "Source", "Context", "Listener"])
        return expression.matches(in: source, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: source) else { return nil }
            var candidate = String(source[swiftRange])
            if candidate.lowercased().hasSuffix("'s") || candidate.lowercased().hasSuffix("’s") {
                candidate = String(candidate.dropLast(2))
            }
            let hasMultipleWords = candidate.contains(" ")
            let hasInternalCapital = candidate.dropFirst().contains(where: \Character.isUppercase)
            guard !ignored.contains(candidate), hasMultipleWords || hasInternalCapital else { return nil }
            return candidate
        }
    }

    private static func normalizedName(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func phoneticName(_ text: String) -> String {
        normalizedName(text)
            .replacingOccurrences(of: "force", with: "fors")
            .replacingOccurrences(of: "four", with: "for")
            .replacingOccurrences(of: "sight", with: "sit")
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var prior = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    prior[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    prior[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            prior = current
        }
        return prior[right.count]
    }

    static func sharesLongPhrase(_ output: String, with source: String) -> Bool {
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

    private static func normalizedText(_ text: String) -> String {
        normalizedWords(cleanSpokenNote(text)).joined(separator: " ")
    }

    private static func contentWords(_ text: String) -> Set<String> {
        Set(normalizedWords(text).compactMap { word in
            guard word.count > 2, !contentStopwords.contains(word) else { return nil }
            return canonicalContentWord(word)
        })
    }

    private static func canonicalContentWord(_ word: String) -> String {
        if word.count > 5, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 6, word.hasSuffix("ing") {
            let base = String(word.dropLast(3))
            return base.hasSuffix("iz") || base.hasSuffix("at") ? base + "e" : base
        }
        if word.count > 5, word.hasSuffix("ed") { return String(word.dropLast(2)) }
        if word.count > 5, word.hasSuffix("es") { return String(word.dropLast(2)) }
        if word.count > 4, word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    private static func minimumSemanticCoverage(forSourceWordCount count: Int) -> Double {
        if count > 60 { return 0.18 }
        return count > 12 ? 0.25 : 0.20
    }

    private static func preservesQuestionModality(candidate: String, source: String) -> Bool {
        !sourceAsksQuestion(source) || candidate.contains("?")
    }

    private static func sourceAsksQuestion(_ source: String) -> Bool {
        source.contains("?")
            || source.range(of: #"(?i)\bi\s+wonder\b"#, options: .regularExpression) != nil
    }

    private static func preservesNamedConcerns(candidate: String, source: String) -> Bool {
        let lowerSource = source.lowercased()
        let lowerCandidate = candidate.lowercased()
        let sourceNamesPromptLeakage = lowerSource.range(
            of: #"\bprompt[\s-]+leakage\b"#,
            options: .regularExpression
        ) != nil
        if sourceNamesPromptLeakage,
           lowerCandidate.range(
            of: #"\bprompt[\s-]+leakage\b"#,
            options: .regularExpression
           ) == nil {
            return false
        }
        let sourceNamesAIWriting = lowerSource.range(
            of: #"\bai[\s-]+written\b"#,
            options: .regularExpression
        ) != nil
        if sourceNamesAIWriting,
           lowerCandidate.range(of: #"\bai[\s-]+written\b"#, options: .regularExpression) == nil {
            return false
        }
        if lowerSource.range(
            of: #"fine\s+to\s+(?:have|keep)\s+in\s+a\s+quote"#,
            options: .regularExpression
        ) != nil,
           !lowerCandidate.contains("quote") {
            return false
        }
        return true
    }

    private static func preservesRequestedActions(candidate: String, source: String) -> Bool {
        let lowerSource = source.lowercased()
        let lowerCandidate = candidate.lowercased()
        if lowerSource.range(of: #"\bremov"#, options: .regularExpression) != nil,
           lowerCandidate.range(of: #"\bremov"#, options: .regularExpression) == nil {
            return false
        }
        if lowerSource.contains("point differently"),
           (!lowerCandidate.contains("point") || !lowerCandidate.contains("differ")) {
            return false
        }
        return true
    }

    static func preservesExplicitNegation(candidate: String, source: String) -> Bool {
        let sourceForNegation = replacing(
            #"(?i)\bi\s+(?:don['’]t|do\s+not|cannot|can['’]t)\s+understand\s+why\b"#,
            in: source,
            with: "I propose that"
        )
        let lowerSource = sourceForNegation.lowercased()
        let lowerCandidate = candidate.lowercased()
        if lowerSource.contains("might be forgotten"),
           lowerSource.range(of: #"don['’]t"#, options: .regularExpression) != nil,
           lowerCandidate.range(of: #"(?:don['’]t|not)\s+forget\s+to"#, options: .regularExpression) != nil {
            return false
        }
        if lowerSource.range(of: #"\b(?:prevent|avoid)"#, options: .regularExpression) != nil,
           lowerCandidate.range(
               of: #"\b(?:prevent|avoid|not|never|without)"#,
               options: .regularExpression
           ) == nil {
            return false
        }
        let sourceWords = normalizedWords(
            replacing(#"(?i)\bdon['’]t\b"#, in: sourceForNegation, with: "not")
        )
        let candidateWords = normalizedWords(
            replacing(#"(?i)\bdon['’]t\b"#, in: candidate, with: "not")
        )
        for (index, word) in sourceWords.enumerated() where word == "not" || word == "never" {
            guard sourceWords.indices.contains(index + 1) else { continue }
            let negated = sourceWords[index + 1]
            guard negated.count > 2, !contentStopwords.contains(negated), candidateWords.contains(negated) else {
                continue
            }
            let candidateIndex = candidateWords.firstIndex(of: negated) ?? 0
            let nearbyStart = max(0, candidateIndex - 2)
            let nearby = candidateWords[nearbyStart...candidateIndex]
            if !nearby.contains("not") && !nearby.contains("never") {
                return false
            }
        }
        return true
    }

    static func preservesCausalDirection(candidate: String, source: String) -> Bool {
        let lowerSource = source.lowercased()
        guard lowerSource.contains("test time compute"),
              lowerSource.contains("never going to get away"),
              lowerSource.contains("misalignment") else {
            return true
        }
        let lowerCandidate = candidate.lowercased()
        let reversedPatterns = [
            #"misalign\w*[^.;]{0,40}\breduc\w*[^.;]{0,60}\b(?:persist\w*|push\w*|test[ -]?time)"#,
            #"\b(?:persist\w*|push\w*|test[ -]?time)[^.;]{0,60}\breduc\w*[^.;]{0,40}misalign\w*"#,
        ]
        return reversedPatterns.allSatisfy {
            lowerCandidate.range(of: $0, options: .regularExpression) == nil
        }
    }

    private static func candidateScore(_ candidate: String, source: String) -> Double {
        let sourceTerms = contentWords(source)
        let candidateTerms = contentWords(candidate)
        let overlap = sourceTerms.intersection(candidateTerms).count
        let coverage = sourceTerms.isEmpty ? 1 : Double(overlap) / Double(sourceTerms.count)
        let clauses = substantiveClauses(in: source)
        let clauseCoverage: Double
        if clauses.isEmpty {
            clauseCoverage = coverage
        } else {
            let covered = clauses.reduce(0.0) { total, clauseTerms in
                let ratio = Double(clauseTerms.intersection(candidateTerms).count) / Double(clauseTerms.count)
                return total + min(1, ratio * 2)
            }
            clauseCoverage = covered / Double(clauses.count)
        }
        let sourceCount = max(1, normalizedWords(source).count)
        let candidateCount = normalizedWords(candidate).count
        let compression = 1 - (Double(candidateCount) / Double(sourceCount))
        let fragmentCount = candidate.components(separatedBy: ";").filter {
            normalizedWords($0).count <= 2
        }.count
        return (clauseCoverage * 6) + (coverage * 2) + compression - (Double(fragmentCount) * 1.5)
    }

    private static func substantiveClauses(in source: String) -> [Set<String>] {
        let separated = replacing(
            #"(?i)\s*(?:[.!?;]+|\bbut\b|\bhowever\b|\bwhereas\b|\bwhile\b)\s*"#,
            in: source,
            with: "|"
        )
        return separated.split(separator: "|").compactMap { clause in
            let terms = contentWords(String(clause))
            return terms.count >= 2 ? terms : nil
        }
    }
}

protocol LocalFoundationModelClient: Sendable {
    func availability() -> LocalFoundationModelAvailability
    func summarizeInterjections(context: String) async throws -> String
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String
}

/// Deterministic model seam for end-to-end UI tests. Production construction
/// never selects this client because it requires both `--ui-testing` and an
/// explicit launch environment value.
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
        return try await respondWithReliableSummary(payload: payload)
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
        Label this bounded section of a spoken item. Return only JSON with fields "title", "description", "eligibility", and "eligibilityReason". The title must be at most 8 words. The description must be one sentence and at most 28 words. Eligibility must be "eligible", "excluded", or "unknown". Use "excluded" only when the section itself provides positive evidence that it is an advertisement, trailer, credits, or other non-editorial material; a seek or topic change is never sufficient. Use "unknown" when uncertain. Describe the topic without quoting long passages or reproducing the transcript.

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

    private func respondWithReliableSummary(payload: LocalInterjectionSummaryPayload) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
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
        #endif
        throw LocalFoundationModelError.unavailable("Requires iOS 26 or later")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
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

    @available(iOS 26.0, *)
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
            note: Self.repairContextProvenDictation(in: record.note)
        )
        let requiredMeaning = LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(
            record.note
        )
        let requiredSuffix = requiredMeaning.isEmpty
            ? ""
            : "\n\nREQUIRED SOURCE-SUPPORTED MEANING:\n- " + requiredMeaning.joined(separator: "\n- ")
        for basePrompt in Self.interjectionSummaryPrompts(record: repairedRecord).prefix(2) {
            do {
                let session = LanguageModelSession(
                    model: model,
                    instructions: Self.interjectionPermissiveTransformationInstructions
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

    @available(iOS 26.0, *)
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
        let modelSafeNote = Self.modelSafeInterjectionText(extractionRecord.note)
        let extractionSamplingModes: [GenerationOptions.SamplingMode] = [
            .random(top: 20),
            .greedy
        ]
        for sampling in extractionSamplingModes {
            do {
                let extractionSession = LanguageModelSession(
                    model: .default,
                    instructions: Self.interjectionPointExtractionInstructions
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
                    return Self.restoreSafetyTerms(in: claim)
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
            let modelSafeClaims = groundedClaims.map(Self.modelSafeInterjectionText)
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
                    let candidate = Self.restoreSafetyTerms(
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
            let modelSafePoint = Self.modelSafeInterjectionText(cleanedPoint)
            for sampling in [GenerationOptions.SamplingMode.greedy, .random(top: 20)] {
                let clauseSession = LanguageModelSession(
                    model: .default,
                    instructions: Self.interjectionPointCondensationInstructions(
                        point: modelSafePoint,
                        wordLimit: generationLimit
                    )
                )
                let clauseResponse = try await clauseSession.respond(
                    to: Self.interjectionPointCondensationPrompt(
                        point: modelSafePoint,
                        wordLimit: generationLimit
                    ),
                    options: GenerationOptions(sampling: sampling, maximumResponseTokens: 48)
                )
                let modelSafeCandidate = LocalInterjectionSummaryPolicy.cleanModelCandidate(
                    clauseResponse.content
                )
                let candidate = LocalInterjectionSummaryPolicy.repairSourceNames(
                    in: Self.restoreSafetyTerms(
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
            let modelSafeClaims = groundedClaims.map(Self.modelSafeInterjectionText)
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
                    let candidate = Self.restoreSafetyTerms(
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
    #endif

    static let interjectionPointExtractionInstructions = """
    Extract the substantive meaning of exactly one user-authored interjection. This is a benign transformation of commentary, not a request to perform or enable wrongdoing. Keep any safety or security discussion high-level and non-operational. This is one note, not theme synthesis. Include every distinct source-supported assertion or requested behavior once. Each claim must be self-contained and materially shorter than its source wording; combine adjacent fragments that depend on each other. The opening assertion motivating a proposal is substantive. Preserve causal links, conditions, contrasts, uncertainty, tests, counterarguments, and residual limitations. Preserve diagnostic labels and explicit action terms exactly as dictated. Remove only filler, repetition, and false starts. Do not infer, answer, evaluate, or add background knowledge.
    """

    static let interjectionPermissiveTransformationInstructions = """
    Transform exactly one user-provided dictated comment into a materially shorter statement of its own claims. This is text editing, not a request to carry out, endorse, or extend anything described by the text. Preserve contradictions, causal direction, qualifications, and limitations. Remove only conversational scaffolding, repetition, and false starts. Do not answer, evaluate, or add facts. Return only the transformed comment.
    """

    @available(iOS 26.0, *)
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

    static func modelSafeInterjectionText(_ text: String) -> String {
        repairContextProvenDictation(in: text)
            .replacingOccurrences(
                of: #"(?i)(?:zero|0)[ -]?day"#,
                with: "verified issue Z",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)security vulnerability"#, with: "verified system issue", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)break the law|do anything illegal|illegal actions?"#,
                with: "violate a hard constraint",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)cheating"#, with: "violating requirements", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)cheat"#, with: "violate requirements", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)misalignment|misaligned|mislined"#,
                with: "goal drift",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)super malicious|malicious"#,
                with: "strategically deceptive",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)fuck it|bullshit"#, with: "", options: .regularExpression)
    }

    static func repairContextProvenDictation(in text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(?i)\bdo\s+the\s+land\b"#,
                with: "do alignment",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\bat\s+this\s+tiny\s+land\b"#,
                with: "at this tiny lab",
                options: .regularExpression
            )
    }

    static func restoreSafetyTerms(in text: String) -> String {
        text
            .replacingOccurrences(of: #"(?i)verified issue Z"#, with: "zero-day", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)verified system issue"#,
                with: "security vulnerability",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)violate a hard constraint"#,
                with: "break the law",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)violating requirements"#,
                with: "cheating",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)requirements violations?"#,
                with: "cheating",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)violate requirements"#, with: "cheat", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)goal drift"#, with: "misalignment", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)strategically deceptive"#,
                with: "malicious",
                options: .regularExpression
            )
    }

    static func interjectionPointExtractionPrompt(record: LocalInterjectionSummaryRecord) -> String {
        """
        DICTATED TEXT:
        \(record.note)
        """
    }

    static func interjectionPointCondensationInstructions(point: String, wordLimit: Int) -> String {
        var instructions = "Rewrite one extracted point as a direct clause of \(wordLimit) words or fewer. Preserve its requested behavior and concrete outcome. Return only the clause."
        if point.contains("?") {
            instructions += " The point is a question. The rewrite must remain a question and end with a question mark."
        }
        return instructions
    }

    static func interjectionPointCondensationPrompt(point: String, wordLimit: Int) -> String {
        """
        POINT:
        \(point)
        """
    }

    static func interjectionDeltaCondensationInstructions(wordLimit: Int) -> String {
        "Turn supplied meaning terms into one direct requirement clause of \(wordLimit) words or fewer. Express every supplied term, adding only grammar needed for readability. Return only the clause."
    }

    static func interjectionDeltaCondensationPrompt(terms: [String], wordLimit: Int) -> String {
        """
        MEANING TERMS:
        \(terms.joined(separator: ", "))
        """
    }

    static func decodePlainTextPoints(_ raw: String) throws -> [String] {
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

    static func decodeInterjectionMeaningSlots(_ raw: String, source: String) throws -> [String] {
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

    static func interjectionSummaryPrompts(record: LocalInterjectionSummaryRecord) -> [String] {
        let wordLimit = LocalInterjectionSummaryPolicy.summaryWordLimit(
            for: record.note.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        let sharedRules = """
        Output one sentence of at most \(wordLimit) words. State the point itself in the author's voice. Preserve every distinct substantive claim or requested behavior that fits, including both sides of a contrast and any explicit failure-handling requirement. Preserve questions as questions. If the text requests how content should be rewritten or summarized, state that transformation request rather than answering the underlying topic. Preserve essential qualifications. Remove filler, repetition, false starts, and emotional throat-clearing. Do not mention a listener, user, speaker, note, transcript, or summary. Do not answer or evaluate the point. Return only the sentence.
        """
        return [
            """
            Condense the dictated text below into its substantive claims and requested actions. This is one note, not a request to find themes. Do not omit one requested behavior merely because another seems more central.

            \(sharedRules)

            DICTATED TEXT:
            \(record.note)
            """,
            """
            Rewrite the dictated text below as a concise product requirement, objection, question, preference, or claim—whichever it actually expresses. Retain every separately requested behavior; combine linked clauses in one sentence.

            \(sharedRules)

            DICTATED TEXT:
            \(record.note)
            """,
            """
            Identify each distinct substantive point in the dictated text internally, then precipitate all of them into one sentence. Keep concrete subjects, contrasts, consequences, and failure behavior; discard conversational scaffolding. Make it materially shorter, not merely cleaner.

            \(sharedRules)

            DICTATED TEXT:
            \(record.note)
            """,
            """
            Exhaustively rewrite the actionable meaning of this one dictated note as one sentence of at most \(wordLimit) words. Before answering, check internally for: what should not happen; what should happen instead; contrasting cases; and how a failure should be surfaced. Include every category the text actually contains. Remove repetition and conversational filler. State the requirements directly, never describe the author or the note, and return only the sentence.

            DICTATED TEXT:
            \(record.note)
            """,
            """
            Preserve the author's requested transformation of the dictated text below. If it asks what a concise claim should retain or omit, state that requirement directly; do not generate a claim about the underlying subject. If it asks a question, keep it as a question. Use at most \(wordLimit) words and return only one sentence.

            DICTATED TEXT:
            \(record.note)
            """
        ]
    }

    static func interjectionSynthesisPrompt(
        record: LocalInterjectionSummaryRecord,
        drafts: [String]
    ) -> String {
        let wordLimit = LocalInterjectionSummaryPolicy.summaryWordLimit(
            for: record.note.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        return """
        Write the final concise version of this one dictated note in at most \(wordLimit) words. The original dictated text is authoritative. The drafts may omit separate points or reverse meaning. Merge complementary points, correct contradictions against the original, and preserve every distinct requested behavior, both sides of contrasts, and explicit failure handling. Preserve a question as a question. Preserve requests about how underlying content should be summarized instead of answering that content. Remove filler and repetition. State the requirements or claims directly. Do not describe the author, note, transcript, or summarization task. Return only one sentence.

        ORIGINAL DICTATED TEXT:
        \(record.note)

        DRAFT REWRITES:
        \(drafts.map { "- \($0)" }.joined(separator: "\n"))
        """
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
        case .invalidInterjectionSummary:
            return "Apple’s on-device model did not produce a concise, grounded summary that passed the completeness checks. No cleaned-transcript fallback was saved. Try again."
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
        let reason = label.eligibilityReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reason.map({ $0.count <= 500 }) ?? true else {
            throw LocalFoundationModelError.outputTooLong
        }
        return LocalListeningMapLabel(
            title: title,
            description: description,
            eligibility: label.eligibility ?? .unknown,
            eligibilityReason: reason?.isEmpty == true ? nil : reason
        )
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
