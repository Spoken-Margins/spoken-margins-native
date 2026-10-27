import Foundation

/// I14 text normalization for the Kitten voice: numbers, years, statistics, units, citations.
///
/// A port of `research/C2/frontend/normalize.py`, which stays the reference: `KittenFrontEndTests`
/// checks every step against `test_vectors.json`. Self-contained on purpose (no num2words, which is
/// LGPL). Digits are ASCII only; other scripts' digits pass through untouched.
public enum SpeechNormalizer {
    /// How a number is read out. Kitten needs help; Kokoro, which was trained on misaki's text, does not (#2705).
    public enum NumberReading: Sendable {
        /// Kitten's workarounds: a comma after 'hundred' and after each scale word, because without them Kitten
        /// drops 'one thousand' and chokes on 'hundred'.
        case kitten
        /// Misaki's reading: num2words' words, split on anything that isn't a letter, with no commas
        /// (`misaki/en.py`, `Lexicon.get_number`, Apache-2.0).
        case misaki

        var separator: String { self == .kitten ? ", " : " " }
    }

    // MARK: Number words

    /// Reads a non-negative integer. Numbers past 18 digits are read digit by digit, because they are
    /// identifiers, not quantities (the Python reference reads them with its unbounded integers).
    static func intWords(_ n: UInt64, style: NumberReading = .kitten) -> String {
        let ones = FrontEndTables.ones, tens = FrontEndTables.tens
        if n < 20 { return ones[Int(n)] }
        if n < 100 { return tens[Int(n / 10)] + (n % 10 != 0 ? "-" + ones[Int(n % 10)] : "") }
        if n < 1000 {
            let rest = n % 100
            // A comma after 'hundred' too (owner's pick, 2026-09-28): without it Kitten chokes on 'hundred'.
            return ones[Int(n / 100)] + " hundred" + (rest != 0 ? style.separator + intWords(rest, style: style) : "")
        }
        for (value, name) in FrontEndTables.scales where n >= value {
            let rest = n % value
            // A comma after the scale word: without it Kitten drops 'one thousand' ('1,250' heard as '250').
            return intWords(n / value, style: style) + " " + name + (rest != 0 ? style.separator + intWords(rest, style: style) : "")
        }
        return String(n)
    }

    /// An ASCII digit string as words: a quantity, or digit by digit when it is too long to be one.
    static func intWords(digits: String, style: NumberReading = .kitten) -> String {
        let trimmed = digits.drop { $0 == "0" }
        if trimmed.isEmpty { return FrontEndTables.ones[0] }
        if trimmed.count > 18 { return digits.map { FrontEndTables.ones[Int(String($0)) ?? 0] }.joined(separator: " ") }
        return intWords(UInt64(trimmed) ?? 0, style: style)
    }

    static func yearWords(_ n: Int, style: NumberReading = .kitten) -> String {
        let ones = FrontEndTables.ones
        if (2000...2009).contains(n) { return "two thousand" + (n > 2000 ? " " + ones[n - 2000] : "") }
        let hi = n / 100, lo = n % 100
        if lo == 0 { return intWords(UInt64(hi), style: style) + " hundred" }
        return intWords(UInt64(hi), style: style) + " " + (lo < 10 ? "oh " + ones[lo] : intWords(UInt64(lo), style: style))
    }

    /// '1,284' -> one thousand..., '61.3' -> sixty-one point three, '0.001' -> zero point zero zero one.
    static func numberWords(_ token: String, style: NumberReading = .kitten) -> String {
        let token = token.replacingLiteral(",", with: "")
        guard let dot = token.firstIndex(of: ".") else { return intWords(digits: token, style: style) }
        let whole = String(token[..<dot]), fraction = token[token.index(after: dot)...]
        let digits = fraction.compactMap { $0.isASCII && $0.isNumber ? FrontEndTables.ones[Int(String($0)) ?? 0] : nil }
        return (whole.isEmpty ? "zero" : intWords(digits: whole, style: style)) + " point " + digits.joined(separator: " ")
    }

    /// 'HbA1c' -> 'H B A one C': mixed letter-digit codes are spelled.
    static func spellCode(_ token: String) -> String {
        token.map { character in
            if let digit = character.wholeNumberValue, character.isASCII { return FrontEndTables.ones[digit] }
            return String(character).uppercased()
        }.joined(separator: " ")
    }

    /// 'nineteen ninety' -> 'nineteen nineties' (decades).
    static func pluralWords(_ words: String) -> String {
        let (head, separator, last) = words.rpartition(" ")
        return head + separator + (last.hasSuffix("y") ? String(last.dropLast()) + "ies" : last + "s")
    }

    static func ordinal(digits: String, style: NumberReading = .kitten) -> String {
        let words = intWords(digits: digits, style: style)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        let lastWord = words.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? words
        let (head, separator, last) = lastWord.contains("-") ? words.rpartition("-") : words.rpartition(" ")
        let ending: String
        if let word = irregular[last] {
            ending = word
        } else if last.hasSuffix("y") {
            ending = String(last.dropLast()) + "ieth"
        } else {
            ending = last + "th"
        }
        return head + separator + ending
    }

    static func currencyWords(symbol: String, number: String, scale: String, style: NumberReading = .kitten) -> String {
        let unit = FrontEndTables.currency[symbol] ?? ""
        if !scale.isEmpty { return "\(numberWords(number, style: style)) \(scale) \(unit)" }
        let plain = number.replacingLiteral(",", with: "")
        let parts = plain.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = String(parts[0]), cents = parts.count > 1 ? String(parts[1]) : ""
        var out = "\(intWords(digits: whole, style: style)) \(whole != "1" ? unit : String(unit.dropLast()))"
        if cents.count == 2, (Int(cents) ?? 0) != 0 { out += " " + intWords(UInt64(cents) ?? 0, style: style) }
        return out
    }

    // MARK: Patterns

    private static let number = "[0-9]{1,3}(?:,[0-9]{3})+(?:\\.[0-9]+)?|[0-9]+(?:\\.[0-9]+)?"
    private static let year = "(1[1-9][0-9][0-9]|20[0-9][0-9])"

    private static let numericCitation = Rx("\\s*\\[[0-9]+(?:\\s*[,–-]\\s*[0-9]+)*\\]")
    private static let parentheticalCitation = Rx(
        "\\s*\\((?!(?:\(FrontEndTables.months))\\b)(?:[A-Z][A-Za-z'’-]+(?: et al\\.)?(?:,| and [A-Z][A-Za-z'’-]+,)? [0-9]{4}[a-z]?(?:; )?)+\\)"
    )
    nonisolated(unsafe) private static let abbreviations: [(Rx, (Rx.Match) -> String)] = [
        (Rx("\\bSt\\.(?=\\s+[A-Z])"), { _ in "Saint" }),
        (Rx("\\bPh\\.D\\."), { _ in "P H D" }),
        (Rx("\\b([ap])\\.m\\."), { ($0.group(1) ?? "").uppercased() + " M" }),
        (Rx("\\bet al\\.(?=\\s*$|\\s+[A-Z])"), { _ in "and colleagues." }),
        (Rx("\\bet al\\."), { _ in "and colleagues" }),
        (Rx("\\be\\.g\\.,?"), { _ in "for example," }),
        (Rx("\\bi\\.e\\.,?"), { _ in "that is," }),
        (Rx("\\bvs\\.?(?=\\s)"), { _ in "versus" }),
        (Rx("\\bapprox\\."), { _ in "approximately" }),
        (Rx("\\bFig\\."), { _ in "Figure" }),
        (Rx("\\bDr\\."), { _ in "Doctor" }),
        (Rx("\\bMr\\."), { _ in "Mister" }),
        (Rx("\\bMrs\\."), { _ in "Missus" }),
        (Rx("\\bNo\\.(?=\\s*\\d)"), { _ in "number" }),
    ]
    private static let dottedInitialism = Rx("\\b((?:[A-Za-z]\\.){2,})")
    private static let mixedCode = Rx("\\b(?=[A-Za-z0-9]*[A-Z])(?=[A-Za-z0-9]*[0-9])[A-Za-z][A-Za-z0-9]*\\b")
    private static let letterThenDigits = Rx("[A-Z][0-9]+")
    private static let versionNumber = Rx("\\b[0-9]+(?:\\.[0-9]+){2,}\\b")
    private static let currencyAmount = Rx("([$£€])\\s?(\(number))(?:\\s?(thousand|million|billion|trillion)\\b)?")
    private static let confidenceInterval95 = Rx("\\b95%\\s*CI\\b")
    private static let confidenceInterval = Rx("\\bCI\\b")
    private static let pEquals = Rx("\\b([pP])\\s*=\\s*")
    private static let pLess = Rx("\\b([pP])\\s*<\\s*")
    private static let pGreater = Rx("\\b([pP])\\s*>\\s*")
    private static let spacedEquals = Rx("\\s=\\s")
    private static let minusSign = Rx("(^|[\\s(])[-−](?=[0-9])")
    private static let dashRange = Rx("(\(number))\\s*[–—]\\s*(\(number))")
    private static let hyphenRange = Rx("(?<![\\w.\\-])(\(number))\\s?-\\s?(\(number))(?![\\w\\-])")
    private static let unitPatterns: [(Rx, String)] = {
        // Longest first; equal lengths keep the reference's order.
        let ordered = FrontEndTables.units.enumerated().sorted {
            $0.element.0.count != $1.element.0.count ? $0.element.0.count > $1.element.0.count : $0.offset < $1.offset
        }.map(\.element)
        return ordered.map { unit, words in
            (Rx("(\(number))\\s?\(NSRegularExpression.escapedPattern(for: unit))(?![A-Za-z])"), words)
        }
    }()
    private static let shortUnitPatterns: [(Rx, String)] = FrontEndTables.shortUnits.map { unit, words in
        (Rx("(\(number)) \(NSRegularExpression.escapedPattern(for: unit))(?![A-Za-z'’])"), words)
    }
    private static let clockTime = Rx("\\b([0-9]{1,2}):([0-9]{2})\\b")
    private static let decade = Rx("\\b(1[0-9]|20)([0-9])0s\\b")
    private static let shortDecade = Rx("['’]([1-9])0s\\b")
    private static let yearRange = Rx("\\b\(year) to \(year)\\b")
    private static let yearAfterCue = Rx("\\b((?i:\(FrontEndTables.yearCue)))\\s+\(year)\\b(?![.,][0-9])")
    private static let parenthesizedYear = Rx("\\(\(year)\\)")
    private static let ordinalNumber = Rx("\\b([0-9]+)(st|nd|rd|th)\\b")
    private static let digitsThenLetters = Rx("(\(number))([A-Za-z]+)\\b")
    private static let bareNumber = Rx("(?<![\\w.])\(number)(?![\\w])")
    private static let brackets = Rx("\\s*[\\[\\]()]\\s*")
    private static let spaceBeforeComma = Rx("\\s+,")
    private static let repeatedCommas = Rx(",(\\s*,)+")
    private static let commaBeforeStop = Rx(",\\s*([.;:!?])")
    private static let edgeCommas = Rx("^,\\s*|,\\s*$")
    private static let repeatedSpaces = Rx("\\s{2,}")

    // MARK: Normalize

    public static func normalize(_ text: String, numbers: NumberReading = .kitten) -> String {
        let style = numbers
        // Strip accents ('Reykjavík' -> 'Reykjavik') but keep Greek letters and µ for the tables below.
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars where scalar.properties.generalCategory != .nonspacingMark {
            scalars.append(scalar)
        }
        var t = String(scalars).precomposedStringWithCanonicalMapping
        // I14 markers: numeric and parenthetical author-year citations are silent.
        t = numericCitation.sub(t, template: "")
        t = parentheticalCitation.sub(t, template: "")
        for (pattern, replacement) in abbreviations { t = pattern.sub(t, replacement) }
        // Dotted initialisms: 'U.S.' -> 'U S'.
        t = dottedInitialism.sub(t) { match in
            (match.group(1) ?? "").filter { $0 != "." }.uppercased().map(String.init).joined(separator: " ") + " "
        }
        // Codes mixing letters and digits with a capital inside ('HbA1c', 'CO2', 'D3') are spelled out.
        t = mixedCode.sub(t) { match in
            let code = match.whole
            if letterThenDigits.fullMatches(code) { return String(code.prefix(1)) + " " + String(code.dropFirst()) }
            return spellCode(code)
        }
        // Version-like numbers: 4.2.1 -> four point two point one.
        t = versionNumber.sub(t) { $0.whole.split(separator: ".", omittingEmptySubsequences: false).map { numberWords(String($0), style: style) }.joined(separator: " point ") }
        // Currency: $12.50, $1.2 billion, £3.
        t = currencyAmount.sub(t) { currencyWords(symbol: $0.group(1) ?? "", number: $0.group(2) ?? "", scale: $0.group(3) ?? "", style: style) }
        // Statistics.
        t = confidenceInterval95.sub(t, template: "95 percent confidence interval")
        t = confidenceInterval.sub(t, template: "confidence interval")
        t = pEquals.sub(t, template: "$1 equals ")
        t = pLess.sub(t, template: "$1 less than ")
        t = pGreater.sub(t, template: "$1 greater than ")
        t = spacedEquals.sub(t, template: " equals ")
        // A minus sign before a number at the start of a word: '-5', '−5'.
        t = minusSign.sub(t, template: "$1minus ")
        // Ranges: 10–20, 10-20 -> 10 to 20 (not codes like COVID-19).
        t = dashRange.sub(t, template: "$1 to $2")
        t = hyphenRange.sub(t, template: "$1 to $2")
        // Units after a number (longest first).
        for (pattern, words) in unitPatterns { t = pattern.sub(t) { ($0.group(1) ?? "") + " " + words } }
        for (pattern, words) in shortUnitPatterns { t = pattern.sub(t) { ($0.group(1) ?? "") + " " + words } }
        for (greek, name) in FrontEndTables.greek { t = t.replacingLiteral(greek, with: " " + name + " ") }
        for (symbol, words) in FrontEndTables.symbols { t = t.replacingLiteral(symbol, with: words) }
        // Clock times: 11:45 -> eleven forty-five, 9:05 -> nine oh five, 9:00 -> nine o'clock.
        t = clockTime.sub(t) { match in
            let hour = match.group(1) ?? "", minute = match.group(2) ?? ""
            let spokenHour = intWords(digits: hour, style: style)
            if minute == "00" { return spokenHour + " o'clock" }
            if minute.hasPrefix("0") { return spokenHour + " oh " + FrontEndTables.ones[Int(String(minute.dropFirst())) ?? 0] }
            return spokenHour + " " + intWords(digits: minute, style: style)
        }
        // Decades: 1990s -> nineteen nineties, '90s -> nineties.
        t = decade.sub(t) { pluralWords(yearWords(Int((($0.group(1) ?? "") + ($0.group(2) ?? "") + "0")) ?? 0, style: style)) }
        t = shortDecade.sub(t) { pluralWords(FrontEndTables.tens[Int($0.group(1) ?? "") ?? 0]) }
        // Years only where the context says year: 'in 1990', 'March 3, 2024', '(2019)', '2010 to 2015'.
        t = yearRange.sub(t) { yearWords(Int($0.group(1) ?? "") ?? 0, style: style) + " to " + yearWords(Int($0.group(2) ?? "") ?? 0, style: style) }
        t = yearAfterCue.sub(t) { ($0.group(1) ?? "") + " " + yearWords(Int($0.group(2) ?? "") ?? 0, style: style) }
        t = parenthesizedYear.sub(t) { "(" + yearWords(Int($0.group(1) ?? "") ?? 0, style: style) + ")" }
        // Ordinals.
        t = ordinalNumber.sub(t) { ordinal(digits: $0.group(1) ?? "", style: style) }
        // Digits glued to letters: '4K', '101A', '3D' -> '4 K'.
        t = digitsThenLetters.sub(t, template: "$1 $2")
        t = bareNumber.sub(t) { numberWords($0.whole, style: style) }
        t = brackets.sub(t, template: ", ")
        t = spaceBeforeComma.sub(t, template: ",")
        t = repeatedCommas.sub(t, template: ",")
        t = commaBeforeStop.sub(t, template: "$1")
        t = edgeCommas.sub(t, template: "")
        t = repeatedSpaces.sub(t, template: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words the front end spells out letter by letter whatever their case.
    static let alwaysSpell = Set(FrontEndTables.alwaysSpell)
}
