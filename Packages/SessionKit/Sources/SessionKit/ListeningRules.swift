import Foundation

/// What a rule does to an episode that matches it (#4046).
public enum ListeningRuleAction: String, Codable, Equatable, Sendable {
    /// The episode is set aside: left out of the Following row, the count and "Add everything new", and listed under
    /// "Skipped by your rules".
    case skip
    /// The episode is labelled a pick and counted. Following is not reordered.
    case more
}

/// Where a rule applies.
public enum ListeningRuleScope: Codable, Equatable, Hashable, Sendable {
    case any
    case show(ListMember)
    /// A list by id. The rule follows the list's members as they change.
    case list(String)
}

/// Where a rule came from, for its origin line.
public enum ListeningRuleOrigin: Codable, Equatable, Hashable, Sendable {
    /// The listener wrote it.
    case listener
    /// Spoken Margins suggested it and the listener turned it on.
    case suggested
    /// It arrived in a friend's list file. The name is the list's.
    case list(String)
    /// The listener's own AI wrote it (#4050), on this date.
    case ai(Date)
}

/// A word rule over episodes (#4046). Stored as record kind `listening_rule`, which Build 29 and later shipped builds never
/// read, so they ignore it. A rule acts only while `isOn` (it is never on until the listener turns it on).
public struct ListeningRule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var action: ListeningRuleAction
    /// As the listener wrote them (a trailing `*` matches a word's start). Build with `ListeningRuleWords.validate`.
    public var words: [String]
    public var scope: ListeningRuleScope
    public var origin: ListeningRuleOrigin
    public var isOn: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        action: ListeningRuleAction,
        words: [String],
        scope: ListeningRuleScope = .any,
        origin: ListeningRuleOrigin = .listener,
        isOn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.action = action
        self.words = words
        self.scope = scope
        self.origin = origin
        self.isOn = isOn
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// What a typed list of words can be (#4046): at most 20 words, 60 characters each, no commas, none empty.
public enum ListeningRuleWords {
    public static let maxWords = 20
    public static let maxWordLength = 60
    /// A listener can keep this many rules.
    public static let maxRules = 200

    /// Whether another rule fits. The caller checks before saving a new rule; saving an existing rule again is always fine.
    public static func hasRoom(forRulesAlreadyKept count: Int) -> Bool { count < maxRules }

    public enum Problem: Equatable, Sendable {
        /// Every word was empty, or only punctuation.
        case noWords
        case tooManyWords
        case wordTooLong(String)
        case wordHasComma(String)

        public var message: String {
            switch self {
            case .noWords: "Write at least one word."
            case .tooManyWords: "A rule can have at most \(ListeningRuleWords.maxWords) words."
            case .wordTooLong: "A word can be at most \(ListeningRuleWords.maxWordLength) characters."
            case .wordHasComma: "A word can’t contain a comma. Separate words with commas instead."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Trimmed, empty words dropped, and a word written twice (ignoring case) kept once.
        case valid([String])
        case invalid(Problem)
    }

    /// Splits a comma-separated field into words, accepting the full-width comma too.
    public static func split(_ field: String) -> [String] {
        field.split(whereSeparator: { $0 == "," || $0 == "，" }).map(String.init)
    }

    public static func validate(_ raw: [String]) -> Outcome {
        var kept: [String] = []
        var seen = Set<String>()
        for word in raw {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            // A word with nothing to match (empty, or only punctuation and stars) is an empty word.
            guard !ListeningRuleMatcher.Pattern.tokens(of: trimmed).isEmpty else { continue }
            if trimmed.unicodeScalars.contains(where: { $0 == "," || $0 == "，" }) { return .invalid(.wordHasComma(trimmed)) }
            if trimmed.count > maxWordLength { return .invalid(.wordTooLong(trimmed)) }
            let key = ListeningRuleMatcher.Pattern(word: trimmed)?.signature ?? trimmed
            if seen.insert(key).inserted { kept.append(trimmed) }
        }
        if kept.isEmpty { return .invalid(.noWords) }
        if kept.count > maxWords { return .invalid(.tooManyWords) }
        return .valid(kept)
    }
}

/// The folded, tokenised text of one episode (#4046): its title, then its summary. Build it once per episode and match
/// every rule against it.
public struct ListeningRuleText: Sendable {
    let tokens: [String]
    let tokenSet: Set<String>

    /// Never part of a pattern, so a phrase can't run from the title into the summary.
    static let boundary = "\u{0}"

    public init(title: String, summary: String?) {
        var all = ListeningRuleMatcher.Pattern.tokens(of: title)
        if let summary, !summary.isEmpty {
            all.append(Self.boundary)
            all.append(contentsOf: ListeningRuleMatcher.Pattern.tokens(of: summary))
        }
        tokens = all
        tokenSet = Set(all)
    }
}

/// Matches rule words against an episode's title and summary (#4046).
///
/// Text and words are folded with `.caseInsensitive`, `.diacriticInsensitive` and `.widthInsensitive`, then cut into words
/// at spaces and punctuation, so "art" doesn't match "start". Apostrophes inside a word stay (and ’ counts as '). A trailing
/// `*` matches the start of the last word. A word with spaces matches as a phrase. Each ideograph and kana is its own word,
/// because those scripts have no spaces, so a Chinese or Japanese word matches as a phrase of its characters.
public struct ListeningRuleMatcher: Sendable {
    struct Pattern: Sendable {
        let word: String
        let tokens: [String]
        let prefixLast: Bool

        /// nil when the word has nothing to match.
        init?(word: String) {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            var body = Substring(trimmed)
            while body.last == "*" { body.removeLast() }
            let tokens = Self.tokens(of: String(body))
            guard !tokens.isEmpty else { return nil }
            self.word = trimmed
            self.tokens = tokens
            prefixLast = body.count != trimmed.count
        }

        var signature: String { tokens.joined(separator: " ") + (prefixLast ? "*" : "") }

        func matches(_ text: ListeningRuleText) -> Bool {
            guard let first = tokens.first else { return false }
            if tokens.count == 1 {
                return prefixLast ? text.tokens.contains { $0.hasPrefix(first) } : text.tokenSet.contains(first)
            }
            guard text.tokenSet.contains(first) else { return false }
            let haystack = text.tokens
            guard haystack.count >= tokens.count else { return false }
            for start in 0...(haystack.count - tokens.count) where haystack[start] == first {
                var matched = true
                for offset in 1..<tokens.count {
                    let have = haystack[start + offset]
                    let want = tokens[offset]
                    let startsOnly = prefixLast && offset == tokens.count - 1
                    if startsOnly ? !have.hasPrefix(want) : have != want { matched = false; break }
                }
                if matched { return true }
            }
            return false
        }

        // MARK: Folding and tokenising

        static func tokens(of raw: String) -> [String] {
            let folded = fold(raw)
            var tokens: [String] = []
            var current = String.UnicodeScalarView()
            func flush() {
                var word = String(current)
                while word.first == "'" { word.removeFirst() }
                while word.last == "'" { word.removeLast() }
                if !word.isEmpty { tokens.append(word) }
                current = String.UnicodeScalarView()
            }
            for scalar in folded.unicodeScalars {
                if apostrophes.contains(scalar) {
                    current.append("'")
                } else if isWordScalar(scalar) {
                    if isUnspacedScript(scalar) {
                        flush()
                        current.append(scalar)
                        flush()
                    } else {
                        current.append(scalar)
                    }
                } else {
                    flush()
                }
            }
            flush()
            return tokens
        }

        /// Case, diacritics and width fold everywhere except in kana, where the voiced and semi-voiced marks tell words apart
        /// (バイク is not ハイク). Whether `.diacriticInsensitive` strips them differs by platform, so kana never see it.
        static func fold(_ raw: String) -> String {
            let all: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            let keepMarks: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
            guard raw.unicodeScalars.contains(where: isKana) else { return raw.folding(options: all, locale: nil) }
            var result = ""
            var run = String.UnicodeScalarView()
            var runIsKana = false
            func flush() {
                guard !run.isEmpty else { return }
                let folded = String(run).folding(options: runIsKana ? keepMarks : all, locale: nil)
                // Width folding turns a half-width voiced mark into a combining one; composing puts ﾊﾞ back to バ.
                result += runIsKana ? folded.precomposedStringWithCanonicalMapping : folded
                run = String.UnicodeScalarView()
            }
            for scalar in raw.unicodeScalars {
                // A combining mark joins the run of the scalar before it.
                let kana = isKana(scalar) || (scalar.properties.generalCategory == .nonspacingMark && runIsKana && !run.isEmpty)
                if kana != runIsKana { flush(); runIsKana = kana }
                run.append(scalar)
            }
            flush()
            return result
        }

        /// Hiragana, katakana and the half-width katakana block.
        private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9F).contains(scalar.value)
        }

        private static let apostrophes: Set<Unicode.Scalar> = ["'", "’", "‘", "ʼ", "`", "´", "＇"]

        private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return true }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }

        private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
            scalar.properties.isIdeographic || isKana(scalar)
        }
    }

    private let patterns: [Pattern]

    /// - Parameter words: as stored on a rule. Words with nothing to match are skipped, so a rule with none matches nothing.
    public init(words: [String]) {
        patterns = words.compactMap(Pattern.init(word:))
    }

    /// The rule word (as the listener wrote it) that matches first, or nil.
    public func firstMatch(in text: ListeningRuleText) -> String? {
        patterns.first { $0.matches(text) }?.word
    }

    public func matches(_ text: ListeningRuleText) -> Bool { firstMatch(in: text) != nil }

    public func matches(title: String, summary: String? = nil) -> Bool {
        matches(ListeningRuleText(title: title, summary: summary))
    }
}
