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
/// A digit after a lone letter ("X0", "K1(R)", "W1,p") reads the same as a citation after a name ("Hepatitis
/// B¹²"), so the document decides (#4254): where it doesn't cite with raised numbers (`PDFCitationStyle`), the
/// digit is an index. On the C1 corpus 540 of 579 such runs were in papers that cite in brackets, and of about
/// 80 read by hand 3 were citations.
///
/// Known gaps: a star after a math letter ("x*", an optimum) is still a marker, and so is a digit after a lone
/// letter in a paper that cites with raised numbers ("T2, T3 and T4"). A one-element formula set level ("O₂")
/// is a marker too. So is a single letter after a word, a number or a bracket ("Idn", "2n", "[0,1]m"), because
/// "WHOᵃ" and a table's "12.5ᵃ" look the same: about 90 runs on C1, none of them a real footnote letter (#4257).
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
        /// The document cites with raised numbers (`PDFCitationStyle.citesWithRaisedNumbers`). True, the cautious
        /// reading, when nobody has counted.
        public var raisedNumbersCite: Bool

        public init(
            text: String, before: String, after: String = "", baselineShift: Double?, lineLooksLikeMath: Bool = false,
            raisedNumbersCite: Bool = true
        ) {
            self.text = text
            self.before = before
            self.after = after
            self.baselineShift = baselineShift
            self.lineLooksLikeMath = lineLooksLikeMath
            self.raisedNumbersCite = raisedNumbersCite
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
    /// Element symbols for `isFormula`. Not "I" ("as I¹") or "B" ("Hepatitis B¹²").
    private static let elements: Set<String> = [
        "H", "C", "N", "O", "S", "P", "F", "Cl", "Br", "Li", "Na", "K", "Ca", "Mg", "Fe", "Si", "Al", "Zn", "Cu",
    ]
    /// Units that take an exponent after a number: "5 cm²", "1650 cm⁻¹".
    private static let units: Set<String> = [
        "m", "cm", "mm", "km", "nm", "µm", "μm", "s", "ms", "g", "kg", "mg", "L", "mL", "K", "Hz", "kHz", "MHz",
        "GHz", "J", "W", "N", "Pa", "mol", "V",
    ]
    /// Lower-case roman numerals some papers use as footnote markers ("ii", "iii,iv"). A single "i" is a letter
    /// like any other.
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
        let letters = text.contains(where: \.isLetter)
        // No citation is numbered 0: "L0", "C0,1".
        if !letters, text.first == "0", previous.isLetter { return .mathIndex }
        // Applied like a function ("GLn(k)", "fn(p)"), or an index list carried on from the run before and into
        // what follows (",a" in "Tsd,ad(t)"). After a name the same run ends at a space or a comma ("Mao1,a, Lu2").
        if letters, let next = run.after.first,
           next == "(" || text.first == "," && !next.isWhitespace && !",.;:".contains(next) {
            return .mathIndex
        }
        // A footnote letter is never followed straight by a digit: "Nav1.2", "Ci1i2" (#4257).
        if text.allSatisfy(\.isLetter), run.after.first.map(isDecimalDigit) == true { return .mathIndex }
        let tokens = before.split(whereSeparator: \.isWhitespace)
        let word = String(before.reversed().prefix { $0.isLetter }.reversed())
        if operatorNames.contains(word) { return .mathIndex }
        if number, let token = tokens.last.map(String.init), isQuantity(token, glued: true)
            || units.contains(word) && token == word && tokens.dropLast().last.map({ isQuantity(String($0)) }) == true {
            // A unit glued to a number ("5cm"), or after a number or another unit ("5 cm", "5 m s⁻¹").
            return .mathIndex
        }
        // A unit under a slash ("7.15 g/cm³", "W/m²"), or alone in brackets as a table heads a column ("(cm²)").
        if number, units.contains(word), let opener = before.dropLast(word.count).last,
           opener == "/" || opener == "(" && run.after.first == ")" {
            return .mathIndex
        }
        // A chemical formula: digits straight before a capital ("H₂O", "CH₃OH") or after element symbols ("CO₂").
        if text.allSatisfy(\.isNumber), previous.isLetter, run.after.first?.isUppercase == true || isFormula(word) {
            return .mathIndex
        }
        // Footnote letters are single ("a", "a,b", "a–c"); a run of letters ("log", "con", "max") is an index.
        if text.range(of: "[a-z]{2,}", options: .regularExpression) != nil,
           !text.split(separator: ",").allSatisfy({ romanNumerals.contains(String($0)) }) {
            return .mathIndex
        }
        // Letters after a lone letter, as in "x", "(h", "set S": a variable's index. Not after an initial in a
        // byline ("Smith Jᵃ,").
        if word.count == 1, !text.contains(where: \.isNumber) {
            let initial = word.first?.isUppercase == true
                && tokens.dropLast().last.map { isName($0) } == true
                && run.after.first(where: { !$0.isWhitespace }).map { $0 == "," } != false
            if !initial { return .mathIndex }
        }
        // Digits after a lone letter ("X0", "K1(R)", "W1,p") follow initials and names too ("Smith J¹",
        // "Hepatitis B¹²"), so they are an index only where the document doesn't cite with raised numbers, and
        // not after a capitalised word ("Smith J¹,²", "Smith, J¹"), the word "I" ("as I⁴ argued") or a letter
        // that ends a number in a name ("roberta-8k⁴"; "4M²" and "2a₁a₂" have no word in them).
        if word.count == 1, text.contains(where: \.isNumber), !run.raisedNumbersCite {
            let alone = tokens.last.map { $0.count == 1 } == true
            let wordBefore = alone ? tokens.dropLast().last : nil
            let afterName = word.first?.isUppercase == true && wordBefore.map { isName(String($0.reversed().drop { ",.".contains($0) }.reversed())) } == true
            let pronoun = word == "I" && wordBefore.map { $0.count >= 2 && $0.allSatisfy(\.isLowercase) } == true
            let token = tokens.last.map(String.init) ?? ""
            let endsANamedNumber = token.dropLast().last?.isNumber == true
                && token.range(of: #"\p{L}{2,}"#, options: .regularExpression) != nil
            if !afterName, !pronoun, !endsANamedNumber { return .mathIndex }
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
                || (0x2100...0x214F).contains(scalar.value) && !(0x2120...0x2122).contains(scalar.value) // letterlike: ℓ, ℝ; not ™
                || (0x2190...0x22FF).contains(scalar.value)   // arrows, operators: ∏, ∑, ∫
                || (0x1D400...0x1D7FF).contains(scalar.value) // math alphanumerics: 𝑥, 𝛽
        }
    }

    /// A capitalised word, as a surname is: "Smith", "Smith-Jones", "O'Neil".
    private static func isName(_ token: some StringProtocol) -> Bool {
        token.count >= 2 && token.first?.isUppercase == true && token.allSatisfy { $0.isLetter || "-'’".contains($0) }
    }

    /// Ends in a norm or absolute-value bar ("‖w‖", "|x|"), a brace or an angle bracket ("{xt}", "⟨C⟩"), or in a
    /// bracket around math ("(1+r)"), not around prose ("(Smith, 2020)").
    private static func closesMath(_ before: String) -> Bool {
        guard let last = before.last else { return false }
        if "‖|}⟩〉\u{232A}".contains(last) { return true }
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
            if depth == 0 {
                // "=" and "/" are left out: "(n = 24)¹" and "(and/or)¹" are prose.
                return inner.contains { "+−^×·".contains($0) || isMathScalar($0) }
            }
            inner.append(character)
        }
        // No opening bracket on this line: a parenthesis that began on the line before.
        return false
    }

    /// A number, a number with a unit ("5cm"), or a unit with or without its exponent ("m", "m-1"). Only `glued`:
    /// a number with a unit, where a lone "s" is left out ("1990s", "her 30s").
    private static func isQuantity(_ token: String, glued: Bool = false) -> Bool {
        let digits = token.prefix { $0.isNumber || $0 == "." || $0 == "," }
        let unit = String(token.dropFirst(digits.count))
        if glued { return digits.first?.isNumber == true && units.contains(unit) && unit != "s" }
        if token.last.map(isDecimalDigit) == true && digits.count == token.count { return true }
        let bare = String(unit.reversed().drop { $0.isNumber || $0 == "-" || $0 == "–" }.reversed())
        return units.contains(bare) && (digits.isEmpty || digits.first?.isNumber == true)
    }

    /// Two or more element symbols and nothing else: "CO", "CH", "NaCl".
    private static func isFormula(_ word: String) -> Bool {
        var rest = Substring(word)
        var count = 0
        while !rest.isEmpty {
            if rest.count >= 2, elements.contains(String(rest.prefix(2))) {
                rest = rest.dropFirst(2)
            } else if elements.contains(String(rest.prefix(1))) {
                rest = rest.dropFirst()
            } else {
                return false
            }
            count += 1
        }
        return count >= 2
    }
}
