import Foundation

/// Checks an on-device model's label for one Listening Map scene before the app stores it (#482).
///
/// The summary is spoken during Skim, so it must not say anything the scene doesn't: every number and every
/// capitalised name in it has to appear in the scene's own text. A label that quotes long runs of the source,
/// or echoes instructions, is rejected. Only scenes the model called editorial keep a summary.
///
/// What counts as a name depends on the transcript's language (#2082). In German and the languages written like it
/// every noun has a capital, so a capital marks no name and only acronyms and words with a capital inside
/// ("YouTube", "McKinsey") are checked, as the community-map server does (#2081). Every other language, and an
/// unknown one, keeps the plain rule.
public enum ListeningMapSummaryValidator {
    public enum Rejection: Error, Equatable, Sendable {
        case empty
        case tooLong
        case excessiveSourceQuotation
        case ungroundedNumber(String)
        case ungroundedName(String)
        case instructionLikeText(String)
    }

    public struct SceneLabel: Equatable, Sendable {
        public let title: String
        public let description: String
        public let eligibility: PortableSceneEligibility
        public let eligibilityReason: String?

        public init(
            title: String,
            description: String,
            eligibility: PortableSceneEligibility,
            eligibilityReason: String?
        ) {
            self.title = title
            self.description = description
            self.eligibility = eligibility
            self.eligibilityReason = eligibilityReason
        }
    }

    public static let maximumTitleWords = 8
    public static let maximumDescriptionWords = 28
    public static let maximumQuotedRunWords = 10
    public static let maximumEligibilityReasonCharacters = 500

    /// Phrases a scene summary never needs, and a prompt injection in a transcript tends to leave behind.
    static let instructionPhrases = ["ignore", "as an ai", "system prompt"]

    static let spelledNumbers = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty"
    ]
    static let spelledTens = ["thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// Titles whose full stop doesn't end a sentence, so the name after them is still checked.
    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "sen", "rep", "gov", "gen", "jr", "sr"]

    public static func validate(
        title rawTitle: String,
        description rawDescription: String,
        eligibility: PortableSceneEligibility?,
        eligibilityReason rawReason: String?,
        sourceText: String,
        language: String? = nil
    ) throws -> SceneLabel {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !description.isEmpty else { throw Rejection.empty }
        guard words(title).count <= maximumTitleWords,
              words(description).count <= maximumDescriptionWords else {
            throw Rejection.tooLong
        }
        let reason = rawReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reason.map({ $0.count <= maximumEligibilityReasonCharacters }) ?? true else {
            throw Rejection.tooLong
        }
        let sourceWords = words(sourceText)
        guard !containsSharedRun(
            lhs: words("\(title) \(description)"),
            rhs: sourceWords,
            length: maximumQuotedRunWords
        ) else {
            throw Rejection.excessiveSourceQuotation
        }
        let generated = "\(title) \(description)"
        let loweredGenerated = " \(words(generated).joined(separator: " ")) "
        if let phrase = instructionPhrases.first(where: { loweredGenerated.contains(" \($0) ") }) {
            throw Rejection.instructionLikeText(phrase)
        }
        let sourceNumbers = numbers(in: sourceText)
        if let number = numbers(in: generated).first(where: { !sourceNumbers.contains($0) }) {
            throw Rejection.ungroundedNumber(number)
        }
        let sourceWordSet = Set(sourceWords)
        let names = capitalisedNames(in: description, nounsCapitalised: capitalisesNouns(language))
        if let name = names.first(where: { !sourceWordSet.contains($0.lowercased()) }) {
            throw Rejection.ungroundedName(name)
        }
        return SceneLabel(
            title: title,
            description: description,
            eligibility: eligibility ?? .unknown,
            eligibilityReason: reason?.isEmpty == true ? nil : reason
        )
    }

    /// What a scene stores as its spoken summary. Only a scene the model positively called editorial keeps
    /// one; an ad, music or an unknown span keeps its title and stays playable, and Skim skips its summary.
    public static func storedSummary(
        for label: SceneLabel?
    ) -> (text: String?, provenance: PortableSummaryProvenance?) {
        guard let label, label.eligibility == .eligible else { return (nil, nil) }
        return (label.description, .modelGenerated)
    }

    /// Every number in `text`, as digits: "1,200" is "1200", "5th" and "1990s" count as "5" and "1990",
    /// and a spelled-out number up to twenty, or a spelled-out multiple of ten up to ninety, counts as its digits.
    static func numbers(in text: String) -> Set<String> {
        var result = Set<String>()
        let withoutGrouping = text.replacingOccurrences(
            of: #"(?<=\d),(?=\d{3})"#,
            with: "",
            options: .regularExpression
        )
        var digits = ""
        for character in withoutGrouping {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                result.insert(normalised(digits))
                digits = ""
            }
        }
        if !digits.isEmpty { result.insert(normalised(digits)) }
        for word in words(text) {
            if let value = spelledNumbers.firstIndex(of: word) { result.insert(String(value)) }
            if let value = spelledTens[word] { result.insert(String(value)) }
        }
        return result
    }

    private static func normalised(_ digits: String) -> String {
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    /// Whether `language`, a BCP 47 tag ("de", "de-CH", "gsw"), is written with a capital on every noun: German and
    /// the languages written like it (Swiss German, Luxembourgish, Bavarian). nil, empty or unknown is not.
    public static func capitalisesNouns(_ language: String?) -> Bool {
        guard let language else { return false }
        let primary = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return ["de", "gsw", "lb", "bar"].contains(primary ?? "")
    }

    /// Capitalised tokens of two or more letters that don't start a sentence, possessive "'s" removed. With
    /// `nounsCapitalised`, for a language that capitalises nouns, only the parts a common noun can't be: acronyms
    /// ("NASA", "LLMs") and words with a capital inside ("YouTube").
    static func capitalisedNames(in text: String, nounsCapitalised: Bool = false) -> [String] {
        var names: [String] = []
        var sentenceStart = true
        for rawToken in text.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken)
            let core = token
                .replacingOccurrences(of: #"['’]s$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.letters.inverted)
            let startsSentence = sentenceStart
            sentenceStart = (token.last.map { ".!?".contains($0) } ?? false)
                && !abbreviations.contains(core.lowercased())
            guard !startsSentence, core.count >= 2, let first = core.first, first.isUppercase else { continue }
            for part in core.split(whereSeparator: { !$0.isLetter }) where part.count >= 2 && part.first!.isUppercase {
                if nounsCapitalised, !isAcronym(part), !hasInnerCapital(part) { continue }
                names.append(String(part))
            }
        }
        return names
    }

    /// All capitals, allowing a plural "s": "NASA", "LLMs".
    private static func isAcronym(_ name: Substring) -> Bool {
        let letters = name.last == "s" ? name.dropLast() : name
        return letters.count >= 2 && letters.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// A capital after a lowercase letter ("YouTube", "McKinsey"), which a German common noun never has.
    private static func hasInnerCapital(_ word: Substring) -> Bool {
        zip(word, word.dropFirst()).contains { $0.0.isLowercase && $0.1.isUppercase }
    }

    static func words(_ text: String) -> [String] {
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
