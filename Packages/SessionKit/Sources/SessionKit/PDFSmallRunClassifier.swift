import Foundation

/// Tells a footnote marker from a math index in a PDF line (#4074). PDFKit gives no superscript or subscript
/// attribute, only size and position, so the extractor finds short runs of smaller type set against the letter
/// before them. Some are citation and footnote markers ("aptitude¹", "effects¹²,¹⁴", "Doeᵃ,ᵇ") that the listener
/// shouldn't hear. Many are math indices ("xₙ", "hₜ", "A_con", "log" under a product sign) set level, or too
/// shallow for a baseline test to see, and silencing them reads "Fᵢ = vᵢ" as "F = v". On the C1 corpus the
/// position test alone silenced 2,758 letter "markers" in 42 of 64 papers.
///
/// A marker is a number, a symbol or a short list of single letters after prose. An index follows a lone or
/// math-font letter, or a math operator, sits in a line of display math, or is a run of letters no footnote uses.
/// This is pure: the caller measures the run and its neighbours.
public enum PDFSmallRunClassifier {
    public enum Kind: Equatable, Sendable {
        /// A citation or footnote marker: silenced.
        case footnoteMarker
        /// A subscript or superscript in math (an index or an exponent): spoken.
        case mathIndex
        /// Neither (an ordinal suffix, a run not shaped like a marker, a run not attached to anything): left as text.
        case text

        public var isSilenced: Bool { self == .footnoteMarker }
    }

    public struct Run: Equatable, Sendable {
        /// The small run as printed.
        public var text: String
        /// The line's text before the run.
        public var before: String
        /// The line's text after the run.
        public var after: String
        /// The run's bottom less the bottom of the letter before it, in units of the line's main type size:
        /// 0 is level, negative is lower. Nil when the positions are unknown.
        public var baselineShift: Double?
        /// The extractor already reads the whole line as display math.
        public var lineLooksLikeMath: Bool

        public init(text: String, before: String, after: String = "", baselineShift: Double?, lineLooksLikeMath: Bool = false) {
            self.text = text
            self.before = before
            self.after = after
            self.baselineShift = baselineShift
            self.lineLooksLikeMath = lineLooksLikeMath
        }
    }

    /// The longest run that can still be a marker list ("12,14,17–19").
    static let maximumLength = 12
    /// Lower than the letter before it by more than this share of the main size: a subscript ("CO₂").
    static let loweredBy = 0.15

    public static func classify(_ run: Run) -> Kind {
        // Compatibility mapping turns Unicode superscripts ("¹", "ⁿ") into the plain characters a font run carries.
        let text = run.text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = run.before.precomposedStringWithCanonicalMapping
        guard !text.isEmpty, text.count <= maximumLength,
              text.range(of: #"^[0-9,–\-*†‡§¶a-z]+$"#, options: .regularExpression) != nil,
              let previous = before.last, !previous.isWhitespace else { return .text }
        if previous.isNumber {
            // "20th", "1st"; an exponent after a digit ("10⁵").
            if ["st", "nd", "rd", "th"].contains(text) { return .text }
            if text.allSatisfy(\.isNumber) { return .mathIndex }
        }
        if let shift = run.baselineShift, shift < -loweredBy { return .mathIndex }
        // Symbols ("†", "*") are markers even in math; a star after a math letter is left for another day.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .footnoteMarker }
        if run.lineLooksLikeMath { return .mathIndex }
        if isMathScalar(previous) { return .mathIndex }
        // Footnote letters are single ("a", "a,b", "a–c"); a run of letters ("log", "con", "max", "th") is an index.
        if text.range(of: "[a-z]{2,}", options: .regularExpression) != nil { return .mathIndex }
        // A lone letter before it, as in "x", "(h", "set S": a variable, not a word that takes a footnote.
        if previous.isLetter {
            let word = before.reversed().prefix { $0.isLetter }
            if word.count == 1 { return .mathIndex }
        }
        if let next = run.after.first(where: { !$0.isWhitespace }), "=+−<>≤≥×/^_".contains(next) { return .mathIndex }
        return .footnoteMarker
    }

    /// A math-font or Greek letter, or a math operator.
    private static func isMathScalar(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x0391...0x03C9).contains(scalar.value)          // Greek
                || (0x2100...0x214F).contains(scalar.value)   // letterlike: ℓ, ℝ
                || (0x2200...0x22FF).contains(scalar.value)   // operators: ∏, ∑, ∫
                || (0x1D400...0x1D7FF).contains(scalar.value) // math alphanumerics: 𝑥, 𝛽
        }
    }
}
