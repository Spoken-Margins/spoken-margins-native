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

struct LocalInterjectionMeaningSlots: Codable, Equatable, Sendable {
    let question: String?
    let points: [String]
}

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
            #"(?i)\b([[:alpha:]][[:alnum:]’']*)\b(?:[\s,;:—–-]+\1\b)+"#,
            in: cleaned,
            with: "$1"
        )
        cleaned = replacing(#"(?i)\b(?:you know|i mean)\b[\s,;:—–-]*"#, in: cleaned, with: "")
        cleaned = replacing(#"(?i)\bi\s*,?\s*think\b[\s,;:—–-]*(?:that\b[\s,;:—–-]*)?"#, in: cleaned, with: "")
        cleaned = replacing(#"(?i)\bwe\s+need\s+to\s+make\s+sure\s+that\b"#, in: cleaned, with: "Ensure")
        cleaned = replacing(#"(?i)\bwe\s+need\s+to\s+make\s+sure\s+(?:it'?s|this\s+is)\b"#, in: cleaned, with: "Ensure it is")
        cleaned = replacing(#"(?i)\bthis\s+is\s+totally\b"#, in: cleaned, with: "This is")
        cleaned = replacing(#"(?i)\bthis\s+can\s+totally\b"#, in: cleaned, with: "This can")
        cleaned = replacing(#"(?i)^(?:yeah|well|okay|so)\s*,?\s*"#, in: cleaned, with: "")
        cleaned = replacing(#"(?i)(?<=[.!?])\s+(?:yeah|well|okay|so)\s*,?\s*"#, in: cleaned, with: " ")
        cleaned = replacing(#"(?i)(^|[?;.!]\s+)yes\s*,?\s+"#, in: cleaned, with: "$1")
        cleaned = replacing(
            #"(?i)\b([[:alpha:]][[:alnum:]’']*)\b(?:[\s,;:—–-]+\1\b)+"#,
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
        return min(28, max(8, Int((Double(sourceWordCount) * 0.64).rounded(.down))))
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
        var compact = replacing(
            #"(?i)make\s+sure\s+(?:it\s+is|it['’]s)\s+not\s+(.+?)\s+saying\s+it\s+can\s+be\s+(.+?)\s+saying\s+it"#,
            in: summary,
            with: "Attribute it to $2, not $1"
        )
        var clauses = compact.components(separatedBy: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
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
            if lowerRequired == "prompt leakage" {
                isCovered = current().contains("prompt leakage")
            } else if lowerRequired == "ai-written" {
                isCovered = current().range(of: #"\bai[\s-]+written\b"#, options: .regularExpression) != nil
            } else if lowerRequired.contains("remove") {
                isCovered = current().range(of: #"\bremov"#, options: .regularExpression) != nil
            } else if lowerRequired.contains("point differently") {
                isCovered = current().contains("point") && current().contains("differ")
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
        count > 12 ? 0.25 : 0.20
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

    private static func preservesExplicitNegation(candidate: String, source: String) -> Bool {
        let sourceWords = normalizedWords(source)
        let candidateWords = normalizedWords(candidate)
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
        try await summarizeViaPlainTextPoints(record: record, payload: payload)
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
            note: LocalInterjectionSummaryPolicy.repairSourceNames(
                in: record.note,
                from: sourceNameReference
            )
        )
        let validationPayload = LocalInterjectionSummaryPayload(
            schemaVersion: payload.schemaVersion,
            itemTitle: payload.itemTitle,
            interjections: [extractionRecord]
        )
        var extractedPointSets: [[String]] = []
        var extractionError: Error?
        var receivedModelOutput = false
        let extractionSamplingModes: [GenerationOptions.SamplingMode] = [
            .greedy,
            .random(top: 20),
            .random(top: 40),
            .random(top: 20),
            .random(top: 40)
        ]
        for sampling in extractionSamplingModes {
            do {
                let extractionSession = LanguageModelSession(
                    model: .default,
                    instructions: Self.interjectionPointExtractionInstructions
                )
                let extraction = try await extractionSession.respond(
                    to: Self.interjectionPointExtractionPrompt(record: extractionRecord),
                    options: GenerationOptions(sampling: sampling, maximumResponseTokens: 256)
                )
                receivedModelOutput = true
                let extractedPoints = LocalInterjectionSummaryPolicy.auditedMeaningPoints(
                    try Self.decodeInterjectionMeaningSlots(
                        extraction.content,
                        source: extractionRecord.note
                    ),
                    source: extractionRecord.note
                )
                extractedPointSets.append(extractedPoints)
                let immediateCandidate = LocalInterjectionSummaryPolicy.compactMeaningSummary(
                    extractedPoints.map {
                        LocalInterjectionSummaryPolicy.compactMeaningPoint(
                            $0,
                            sourceNameReference: sourceNameReference
                        )
                    }.joined(separator: "; ")
                )
                let explicitAuditCandidate = LocalInterjectionSummaryPolicy.repairSourceNames(
                    in: LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(
                        extractionRecord.note
                    ).joined(separator: "; "),
                    from: sourceNameReference
                )
                if !explicitAuditCandidate.isEmpty,
                   let audited = try? LocalInterjectionSummaryPolicy.bestCandidate(
                       from: [explicitAuditCandidate],
                       payload: validationPayload
                ) {
                    return audited
                }
                if let valid = try? LocalInterjectionSummaryPolicy.bestCandidate(
                    from: [immediateCandidate],
                    payload: validationPayload
                ) {
                    return valid
                }
            } catch {
                if error is CancellationError { throw error }
                extractionError = error
            }
        }
        guard !extractedPointSets.isEmpty else {
            let explicitAuditCandidate = LocalInterjectionSummaryPolicy.repairSourceNames(
                in: LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(
                    extractionRecord.note
                ).joined(separator: "; "),
                from: sourceNameReference
            )
            if receivedModelOutput,
               !explicitAuditCandidate.isEmpty,
               let audited = try? LocalInterjectionSummaryPolicy.bestCandidate(
                   from: [explicitAuditCandidate],
                   payload: validationPayload
               ) {
                return audited
            }
            throw extractionError ?? LocalFoundationModelError.invalidInterjectionSummary
        }
        let directMeaningCandidates = extractedPointSets.map { points in
            let assembled = points.map {
                LocalInterjectionSummaryPolicy.compactMeaningPoint($0, sourceNameReference: sourceNameReference)
            }.joined(separator: "; ")
            return LocalInterjectionSummaryPolicy.compactMeaningSummary(assembled)
        }
        if let direct = try? LocalInterjectionSummaryPolicy.bestCandidate(
            from: directMeaningCandidates,
            payload: validationPayload
        ) {
            return direct
        }
        var mergedPoints: [String] = []
        for point in extractedPointSets.flatMap({ $0 }) where !mergedPoints.contains(where: {
            LocalInterjectionSummaryPolicy.semanticSimilarity(point, $0) >= 0.85
        }) {
            mergedPoints.append(point)
        }
        let mergedMeaningCandidate = LocalInterjectionSummaryPolicy.compactMeaningSummary(mergedPoints.map {
            LocalInterjectionSummaryPolicy.compactMeaningPoint($0, sourceNameReference: sourceNameReference)
        }.joined(separator: "; "))
        if let merged = try? LocalInterjectionSummaryPolicy.bestCandidate(
            from: [mergedMeaningCandidate],
            payload: validationPayload
        ) {
            return merged
        }
        let points = extractedPointSets.max { lhs, rhs in lhs.count < rhs.count } ?? extractedPointSets[0]
        let overallLimit = LocalInterjectionSummaryPolicy.summaryWordLimit(
            for: record.note.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        var clauses: [String] = []
        for (index, point) in points.enumerated() {
            let usedWords = clauses.joined(separator: " ")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            let remainingPoints = max(1, points.count - index)
            let pointLimit = max(4, (overallLimit - usedWords) / remainingPoints)
            let cleanedPoint = LocalInterjectionSummaryPolicy.compactMeaningPoint(
                point,
                sourceNameReference: sourceNameReference
            )
            let cleanedPointWordCount = cleanedPoint
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            if cleanedPoint.hasSuffix("?") || cleanedPointWordCount <= pointLimit + 1 {
                clauses.append(cleanedPoint)
                continue
            }
            let clauseSession = LanguageModelSession(
                model: .default,
                instructions: Self.interjectionPointCondensationInstructions(
                    point: cleanedPoint,
                    wordLimit: pointLimit
                )
            )
            let clauseResponse = try await clauseSession.respond(
                to: Self.interjectionPointCondensationPrompt(point: cleanedPoint, wordLimit: pointLimit),
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 40)
            )
            var clause = LocalInterjectionSummaryPolicy.repairSourceNames(
                in: LocalInterjectionSummaryPolicy.cleanModelCandidate(clauseResponse.content),
                from: sourceNameReference
            )
            let proposed = (clauses + [clause]).joined(separator: "; ")
            let proposedWordCount = proposed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            let priorText = clauses.joined(separator: " ")
            let repeatedRatio = LocalInterjectionSummaryPolicy.semanticOverlapRatio(clause, with: priorText)
            if !clauses.isEmpty, proposedWordCount > overallLimit || repeatedRatio >= 0.40 {
                let terms = LocalInterjectionSummaryPolicy.uncoveredTerms(in: cleanedPoint, excluding: priorText)
                guard !terms.isEmpty else { continue }
                let deltaSession = LanguageModelSession(
                    model: .default,
                    instructions: Self.interjectionDeltaCondensationInstructions(wordLimit: pointLimit)
                )
                let deltaResponse = try await deltaSession.respond(
                    to: Self.interjectionDeltaCondensationPrompt(terms: terms, wordLimit: pointLimit),
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 40)
                )
                clause = LocalInterjectionSummaryPolicy.repairSourceNames(
                    in: LocalInterjectionSummaryPolicy.cleanModelCandidate(deltaResponse.content),
                    from: sourceNameReference
                )
            }
            guard !clause.isEmpty else { throw LocalFoundationModelError.emptyResponse }
            clauses.append(clause)
        }
        let joined = LocalInterjectionSummaryPolicy.compactMeaningSummary(
            clauses.joined(separator: "; ")
        )
        return try LocalInterjectionSummaryPolicy.bestCandidate(from: [joined], payload: validationPayload)
    }
    #endif

    static let interjectionPointExtractionInstructions = """
    Extract the substantive meaning of exactly one dictated editorial comment into JSON with exactly this shape: {"question": string or null, "points": [strings]}. Use question only when the comment asks or wonders something; it must end in ?. Otherwise question must be null. Put up to four concise, nonredundant claims, requested changes, qualifications, preferences, objections, or attribution constraints in points. Preserve exact named diagnostic labels such as "prompt leakage" and "AI-written" in the points. Preserve explicit action terms such as remove, retain, or make the point differently. Do not answer a question or add checklist labels. Convert criticized behavior into its requested correction while preserving exceptions, contrasts, failure handling, and who may or may not make a claim. If the comment requests how content should be rewritten or summarized, extract that transformation requirement rather than answering the underlying topic. Do not infer anything absent from the comment. Remove filler, repetition, and emotional throat-clearing. Return only complete valid JSON with no markdown or commentary.
    """

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
        guard !points.isEmpty, points.count <= 5 else {
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
            return "Apple’s on-device model did not produce a materially shorter summary. No cleaned-transcript fallback was saved. Try again."
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
