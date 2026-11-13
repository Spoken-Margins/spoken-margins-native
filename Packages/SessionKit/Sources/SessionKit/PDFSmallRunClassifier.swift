import Foundation

/// Tells a footnote marker from a math index in a PDF line (#4074). PDFKit gives no superscript or subscript
/// attribute, only size and position, so the extractor finds short runs of smaller type set against the letter
/// before them. Some are citation and footnote markers ("aptitude¹", "effects¹²,¹⁴", "Doeᵃ,ᵇ") that the listener
/// shouldn't hear. Many are math indices ("xₙ", "hₜ", "A_con", "log" under a product sign) set level, or too
/// shallow for a baseline test to see, and silencing them reads "Fᵢ = vᵢ" as "F = v". On the C1 corpus the
/// position test alone silenced 2,758 letter "markers" in 42 of 64 papers.
///
/// A marker is a number, a symbol or a short list of single letters after prose. An index follows a lone or
/// math-font letter, an operator or an operator name ("max", "lim"), a bracket around math or a unit; it sits in
/// a line of display math, or it is a run of letters no footnote uses. The run's shape (characters, length,
/// attachment) is checked the way the extractor's `superscriptRanges` checks it. This is pure: the caller
/// measures the run and its neighbours.
///
/// Known gaps: a star after a math letter ("x*", an optimum) is still a marker, and so is a digit after a lone
/// letter outside math ("x2" in prose), because bylines ("Smith J¹,²") and names ("Hepatitis B¹²") look the same.
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
        /// The extractor reads the whole line as display math. Pass its display-math test, not the looser
        /// `looksLikeMath`, which counts "=" and "+" and would speak the markers of a prose line with a sum in it.
        public var lineLooksLikeMath: Bool

        public init(text: String, before: String, after: String = "", baselineShift: Double?, lineLooksLikeMath: Bool = false) {
            self.text = text
            self.before = before
            self.after = after
            self.baselineShift = baselineShift
            self.lineLooksLikeMath = lineLooksLikeMath
        }
    }

    /// The longest run, in UTF-16 units, that can still be a marker list ("12,14,17–19").
    static let maximumLength = 12
    /// Lower than the letter before it by more than this share of the main size: a subscript ("CO₂").
    static let loweredBy = 0.15

    /// Names set upright in math that take an index: "maxᵢ", "lim_n", "log₂", and dimensionless numbers ("Re_c").
    private static let operatorNames: Set<String> = [
        "max", "min", "argmax", "argmin", "arg", "lim", "sup", "inf", "log", "ln", "exp", "det", "tr", "Pr",
        "Re", "Nu", "Pe",
    ]
    /// Units that take an exponent after a number: "5 cm²", "1650 cm⁻¹".
    private static let units: Set<String> = [
        "m", "cm", "mm", "km", "nm", "µm", "μm", "s", "ms", "g", "kg", "mg", "L", "mL", "K", "Hz", "kHz", "MHz",
        "GHz", "J", "W", "N", "Pa", "mol", "V",
    ]
    /// Lower-case roman numerals some papers use as footnote markers; "i", "v" and "x" alone are indices.
    private static let romanNumerals: Set<String> = ["ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii"]

    public static func classify(_ run: Run) -> Kind {
        var text = Substring(run.text)
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        let before = run.before.precomposedStringWithCanonicalMapping
        guard !text.isEmpty, text.utf16.count <= maximumLength,
              text.range(of: #"^[0-9,–\-*†‡§¶a-z]+$"#, options: .regularExpression) != nil,
              let previous = before.last, !previous.isWhitespace else { return .text }
        let number = text.range(of: #"^[–\-]?[0-9]+$"#, options: .regularExpression) != nil
        if isDecimalDigit(previous) {
            // "20th", "1st"; an exponent after a digit ("10⁵", "10⁻⁵").
            if ["st", "nd", "rd", "th"].contains(text) { return .text }
            if number { return .mathIndex }
        }
        if let shift = run.baselineShift, shift < -loweredBy { return .mathIndex }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .footnoteMarker }
        if run.lineLooksLikeMath || isMathScalar(previous) || closesMath(before) { return .mathIndex }
        let tokens = before.split(whereSeparator: \.isWhitespace)
        let word = String(before.reversed().prefix { $0.isLetter }.reversed())
        if operatorNames.contains(word) { return .mathIndex }
        if number, units.contains(word), let token = tokens.last {
            // Glued ("5cm") or after a number ("5 cm").
            let afterNumber = token.count > word.count || tokens.dropLast().last?.last.map(isDecimalDigit) == true
            if afterNumber { return .mathIndex }
        }
        // Footnote letters are single ("a", "a,b", "a–c"); a run of letters ("log", "con", "max") is an index.
        if text.range(of: "[a-z]{2,}", options: .regularExpression) != nil, !romanNumerals.contains(String(text)) {
            return .mathIndex
        }
        // Letters after a lone letter, as in "x", "(h", "set S": a variable's index. Not after an initial in a
        // byline ("Smith Jᵃ,"), and not digits, which follow initials and names ("Smith J¹", "Hepatitis B¹²").
        if word.count == 1, !text.contains(where: \.isNumber) {
            let initial = word.first?.isUppercase == true
                && tokens.dropLast().last.map { $0.count >= 2 && $0.first?.isUppercase == true && $0.allSatisfy(\.isLetter) } == true
                && run.after.first(where: { !$0.isWhitespace }).map { $0 == "," } != false
            if !initial { return .mathIndex }
        }
        if let next = run.after.first(where: { !$0.isWhitespace }), "=+−<>≤≥×·/^_".contains(next) || isMathScalar(next) {
            return .mathIndex
        }
        return .footnoteMarker
    }

    private static func isDecimalDigit(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
    }

    /// A math-font or Greek letter, an arrow or a math operator.
    private static func isMathScalar(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x0391...0x03C9).contains(scalar.value)          // Greek
                || (0x2100...0x214F).contains(scalar.value)   // letterlike: ℓ, ℝ
                || (0x2190...0x22FF).contains(scalar.value)   // arrows, operators: ∏, ∑, ∫
                || (0x1D400...0x1D7FF).contains(scalar.value) // math alphanumerics: 𝑥, 𝛽
        }
    }

    /// Ends in a norm or absolute-value bar ("‖w‖", "|x|"), or in a bracket around math ("(1+r)"), not around
    /// prose ("(Smith, 2020)").
    private static func closesMath(_ before: String) -> Bool {
        guard let last = before.last else { return false }
        if last == "‖" || last == "|" { return true }
        let opening: Character
        switch last {
        case ")": opening = "("
        case "]": opening = "["
        default: return false
        }
        var depth = 0
        var inner: [Character] = []
        for character in before.reversed() {
            if character == last { depth += 1 } else if character == opening { depth -= 1 }
            if depth == 0 { break }
            inner.append(character)
        }
        return inner.contains { "+−=/^×·".contains($0) || isMathScalar($0) }
    }
}
