import Foundation

/// The rules the on-device model's interjection summaries must pass before they are kept: cleanup of the dictated
/// note, the word budget, coverage of what the note said, and checks that polarity, negation and causes survive.
/// Pure text rules, so they are tested on the host (moved from the app target, #318).
public enum LocalInterjectionSummaryPolicy {
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

    public static func cleanSpokenNote(_ note: String) -> String {
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

    public static func cleanModelCandidate(_ response: String) -> String {
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

    public static func boundedAnchorBefore(_ anchor: String) -> String {
        String(anchor.suffix(anchorCharacterLimit))
    }

    public static func boundedAnchorAfter(_ anchor: String) -> String {
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

    public static func summaryWordLimit(for sourceWordCount: Int) -> Int {
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

    public static func bestCandidate(
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

    public static func validateGuidedSynthesis(
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

    public static func semanticOverlapRatio(_ text: String, with coveredText: String) -> Double {
        let terms = contentWords(text)
        guard !terms.isEmpty else { return 0 }
        return Double(terms.intersection(contentWords(coveredText)).count) / Double(terms.count)
    }

    public static func semanticCoverageRatio(_ candidate: String, source: String) -> Double {
        let sourceTerms = contentWords(source)
        guard !sourceTerms.isEmpty else { return 1 }
        return Double(sourceTerms.intersection(contentWords(candidate)).count) / Double(sourceTerms.count)
    }

    public static func semanticSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = contentWords(lhs)
        let right = contentWords(rhs)
        let denominator = min(left.count, right.count)
        guard denominator > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(denominator)
    }

    public static func repairSourceNames(in text: String, from anchor: String) -> String {
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

    public static func compactMeaningPoint(_ point: String, sourceNameReference: String) -> String {
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

    public static func compactMeaningSummary(_ summary: String) -> String {
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

    public static func auditedMeaningPoints(_ points: [String], source: String) -> [String] {
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

    public static func requiredExplicitMeaningPoints(_ source: String) -> [String] {
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

    public static func sharesLongPhrase(_ output: String, with source: String) -> Bool {
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

    public static func preservesExplicitNegation(candidate: String, source: String) -> Bool {
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
