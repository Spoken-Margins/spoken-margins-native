import Foundation

/// Where in the source a listener says they are, in the unit they used (#2707): a page, a percent, a chapter or a
/// time. A paper book has pages, an e-book a percent, an audiobook a chapter or a clock; a place keeps the unit it
/// was given in and is never converted to another ("page 118" is never "about 1:40:00").
///
/// `LiveSessionPositionMap` holds a clock position in milliseconds for the sessions that have one, exactly as before.
/// A place in any other unit is stored beside it, as new optional fields, so a session saved by an earlier build reads
/// unchanged and an earlier build reading a new one ignores the extra fields (and still has the typed text).
public struct LiveSessionPlace: Codable, Equatable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case time
        case page
        case percent
        case chapter

        /// What an error message calls it: "The page you stopped at is before the page you started at".
        public var noun: String {
            switch self {
            case .time: "time"
            case .page: "page"
            case .percent: "percentage"
            case .chapter: "chapter"
            }
        }
    }

    public var unit: Unit
    /// Milliseconds for a time, a page or chapter number, or a percent from 0 to 100.
    public var value: Double

    public init?(unit: Unit, value: Double) {
        guard value.isFinite, Self.range(of: unit).contains(value) else { return nil }
        if unit == .page || unit == .chapter, value.rounded() != value { return nil }
        self.unit = unit
        self.value = value
    }

    static func range(of unit: Unit) -> ClosedRange<Double> {
        switch unit {
        case .time: 0...604_800_000 // a week
        case .page: 0...99_999
        case .percent: 0...100
        case .chapter: 0...9_999
        }
    }

    public static func time(ms: Int) -> LiveSessionPlace? { LiveSessionPlace(unit: .time, value: Double(ms)) }

    /// "page 118", "40%", "chapter 7", "1:23:10".
    public var label: String {
        switch unit {
        case .time: LiveSessionPositionMap.clock(Int(max(0, min(value, 1e12))))
        case .page: "page \(Self.number(value))"
        case .percent: Self.number(value) + "%"
        case .chapter: "chapter \(Self.number(value))"
        }
    }

    /// The label with its first letter capitalised, for a heading or a field the listener reads: "Page 118".
    public var sentenceLabel: String { label.prefix(1).uppercased() + label.dropFirst() }

    /// A whole number plainly, otherwise one decimal: 40, 40.5.
    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e12 ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Units for a kind

    /// The unit a bare number means in the "chapter or page" field: "118" in a paper book is a page, "7" in an
    /// audiobook is a chapter, "40" in an e-book (or anything else) is a percent.
    public static func defaultUnit(for kind: ElsewhereKind) -> Unit {
        switch kind {
        case .paper, .meeting: .page
        case .audiobook: .chapter
        case .other: .percent
        }
    }

    /// The units the "Where are you?" field offers for a kind, the default first. The clock is its own field, so
    /// only the other units are here; a meeting has the clock and, rarely, a page or slide.
    public static func offeredUnits(for kind: ElsewhereKind) -> [Unit] {
        let first = defaultUnit(for: kind)
        return [first] + [Unit.page, .chapter, .percent].filter { $0 != first }
    }

    // MARK: Reading what the listener types or says

    /// Reads what the listener typed into a "where" field: "p. 118", "page 118", "118", "ch 7", "chapter seven", "40%",
    /// "40 percent", "12:30", "1:12:30". A bare number is in `defaultUnit` (minutes, for a clock). Nil for anything it
    /// can't read, which the caller keeps as the listener's own words. `allowsTime` off leaves a clock like "12:30" as
    /// words, for a field that is for chapters and pages.
    public static func parse(_ text: String, defaultUnit: Unit, allowsTime: Bool = true) -> LiveSessionPlace? {
        match(text, defaultUnit: defaultUnit, allowsTime: allowsTime)?.place
    }

    /// Like `parse`, but only when the whole text is the place ("p. 118", "chapter seven", "40%"), not a place inside
    /// other words ("Chapter 7: The Wall", "Chapter 3, page 40"). This is what is kept as the listener's checkpoint and
    /// what replaces their words with a normalised label; words with more in them stay exactly as typed.
    public static func parseWhole(_ text: String, defaultUnit: Unit, allowsTime: Bool = true) -> LiveSessionPlace? {
        guard let found = match(text, defaultUnit: defaultUnit, allowsTime: allowsTime), found.isWhole else { return nil }
        return found.place
    }

    private static func match(_ text: String, defaultUnit: Unit, allowsTime: Bool) -> (place: LiveSessionPlace, isWhole: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTypedLength else { return nil }
        let tokens = tokenize(trimmed)
        if tokens.count == 1, case let .clock(clock) = tokens[0] {
            guard allowsTime, let ms = LiveSessionPositionMap.parse(clock), let place = time(ms: ms) else { return nil }
            return (place, true)
        }
        if let (value, consumed) = number(in: tokens, at: 0), consumed == tokens.count {
            if defaultUnit == .time {
                guard allowsTime, value.rounded() == value, let place = time(ms: Int(value) * 60_000) else { return nil }
                return (place, true)
            }
            return LiveSessionPlace(unit: defaultUnit, value: value).map { ($0, true) }
        }
        if let found = firstPlace(in: tokens) {
            // Only a trailing full stop or the like may follow a place that is the whole text.
            let whole = found.range.lowerBound == 0 && tokens[found.range.upperBound...].allSatisfy { token in
                if case .symbol = token { return true } else { return false }
            }
            return (found.place, whole)
        }
        if allowsTime, let clock = tokens.lazy.compactMap({ token -> String? in
            if case let .clock(clock) = token { return clock } else { return nil }
        }).first, let ms = LiveSessionPositionMap.parse(clock), let place = time(ms: ms) {
            return (place, false)
        }
        return nil
    }

    /// A place said inside a sentence: "I'm on page 118", "about 40 percent", "this is chapter seven". Only a number
    /// next to the word for its unit counts, never a bare number and never a clock time (those are too ambiguous in
    /// speech: "the call at 3:30"). The first one wins. Nil when there is none.
    public static func hear(in text: String) -> LiveSessionPlace? {
        firstPlace(in: tokenize(String(text.prefix(maxScanLength))))?.place
    }

    static let maxTypedLength = 200
    static let maxScanLength = 2_000

    // MARK: Tokens

    private enum Token: Equatable {
        case word(String)
        case number(Double)
        case clock(String)
        case symbol(Character)
    }

    private static let pageWords: Set<String> = ["page", "pages", "pg", "pgs", "p", "pp", "pagina", "seite"]
    private static let chapterWords: Set<String> = ["chapter", "chapters", "chap", "chapt", "ch", "chp", "capitulo", "chapitre", "kapitel", "capitolo"]
    private static let percentWords: Set<String> = ["percent", "pct", "prozent", "procent", "percento", "porcento"]
    private static let percentPairs: [[String]] = [["per", "cent"], ["per", "cento"], ["por", "ciento"], ["por", "cento"], ["pour", "cent"]]
    private static let fillers: Set<String> = ["number", "no", "num", "nr"]

    private static func tokenize(_ text: String) -> [Token] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        // Digits of other scripts and full-width digits read as the digits they are.
        let chars = folded.map { char -> Character in
            if char.isNumber, char.unicodeScalars.count == 1, let digit = char.wholeNumberValue, digit < 10 { return Character(String(digit)) }
            return char
        }
        func isDigit(_ index: Int) -> Bool { index < chars.count && chars[index].isASCII && chars[index].isNumber }
        func digits(from start: Int) -> (text: String, end: Int) {
            var end = start
            while isDigit(end) { end += 1 }
            return (String(chars[start..<end]), end)
        }
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace {
                index += 1
            } else if isDigit(index) {
                var (text, end) = digits(from: index)
                var groups = [text]
                while end + 1 < chars.count, chars[end] == ":", isDigit(end + 1), groups.count < 3 {
                    let next = digits(from: end + 1)
                    groups.append(next.text)
                    end = next.end
                }
                if groups.count > 1 {
                    tokens.append(.clock(groups.joined(separator: ":")))
                } else {
                    if end + 1 < chars.count, chars[end] == ".", isDigit(end + 1) {
                        let fraction = digits(from: end + 1)
                        text += "." + fraction.text
                        end = fraction.end
                    }
                    tokens.append(.number(Double(text) ?? 0))
                }
                index = end
            } else if char.isLetter {
                var end = index
                while end < chars.count, chars[end].isLetter { end += 1 }
                tokens.append(.word(String(chars[index..<end])))
                index = end
            } else {
                tokens.append(.symbol(char))
                index += 1
            }
        }
        return tokens
    }

    // MARK: Numbers

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tensNumbers: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// A number at `index`: digits, or English number words up to 999 ("seven", "twenty one", "one hundred and eighteen").
    /// Words of other languages are not read: no guessing. Returns the value and how many tokens it used.
    private static func number(in tokens: [Token], at index: Int) -> (Double, Int)? {
        guard index < tokens.count else { return nil }
        if case let .number(value) = tokens[index] { return (value, 1) }
        var total = 0
        var consumed = 0
        var cursor = index
        while cursor < tokens.count {
            // "twenty-one": a hyphen between two number words.
            if consumed > 0, case .symbol("-") = tokens[cursor], cursor + 1 < tokens.count, case let .word(next) = tokens[cursor + 1],
               smallNumbers[next] != nil || tensNumbers[next] != nil {
                consumed += 1
                cursor += 1
                continue
            }
            guard case let .word(word) = tokens[cursor] else { break }
            if let small = smallNumbers[word] {
                let rest = total % 100
                let fits = small >= 10 ? rest == 0 : (rest == 0 || (rest >= 20 && rest % 10 == 0))
                guard fits else { break }
                total += small
            } else if let tens = tensNumbers[word] {
                guard total % 100 == 0 else { break }
                total += tens
            } else if word == "hundred" {
                guard total >= 1, total <= 9 else { break }
                total *= 100
            } else if word == "and", total >= 100, total % 100 == 0, cursor + 1 < tokens.count,
                      case let .word(next) = tokens[cursor + 1], smallNumbers[next] != nil || tensNumbers[next] != nil {
                // "one hundred and eighteen"
            } else {
                break
            }
            consumed += 1
            cursor += 1
        }
        return consumed > 0 ? (Double(total), consumed) : nil
    }

    /// A chapter given as a Roman numeral ("IV"), two letters or more so that "I" and "V" in a sentence aren't read.
    private static func romanNumber(_ word: String) -> Double? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        guard word.count >= 2, word.count <= 8, word.allSatisfy({ values[$0] != nil }) else { return nil }
        let numerals = word.map { values[$0] ?? 0 }
        var total = 0
        for (offset, value) in numerals.enumerated() {
            total += offset + 1 < numerals.count && value < numerals[offset + 1] ? -value : value
        }
        guard total >= 1, total <= 100, romanText(total) == word else { return nil }
        return Double(total)
    }

    private static func romanText(_ number: Int) -> String {
        var remaining = number
        var text = ""
        for (value, numeral) in [(100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
            while remaining >= value {
                text += numeral
                remaining -= value
            }
        }
        return text
    }

    // MARK: Matching

    /// The first place in the tokens and the tokens it covers.
    private static func firstPlace(in tokens: [Token]) -> (place: LiveSessionPlace, range: Range<Int>)? {
        for index in tokens.indices {
            if case let .word(word) = tokens[index] {
                let unit: Unit? = pageWords.contains(word) ? .page : (chapterWords.contains(word) ? .chapter : nil)
                if let unit, let found = placeAfterKeyword(unit, keyword: word, tokens: tokens, from: index + 1) {
                    return (found.place, index..<found.end)
                }
            }
            if let (value, used) = number(in: tokens, at: index), isPercentMarker(tokens, at: index + used),
               let place = LiveSessionPlace(unit: .percent, value: value) {
                return (place, index..<(index + used + percentMarkerLength(tokens, at: index + used)))
            }
        }
        return nil
    }

    /// Words that are short for the unit and may be followed by a full stop: "p. 118", "ch. 7".
    private static let abbreviations: Set<String> = ["p", "pp", "pg", "pgs", "ch", "chap", "chapt", "chp"]

    /// The number after "page" or "chapter", skipping "number", "no." and "#": "page number 118", "p. 118", "ch #7". A
    /// full stop is skipped only after an abbreviation, so "the chapter. Two things stood out" is not chapter 2, and a
    /// range ("pp. 12-14") is not read as its first page.
    private static func placeAfterKeyword(_ unit: Unit, keyword: String, tokens: [Token], from start: Int) -> (place: LiveSessionPlace, end: Int)? {
        var cursor = start
        skipping: for _ in 0..<2 {
            guard cursor < tokens.count else { break }
            switch tokens[cursor] {
            case .symbol(".") where abbreviations.contains(keyword) || cursor > start: cursor += 1
            case .symbol("#"): cursor += 1
            case let .word(word) where fillers.contains(word): cursor += 1
            default: break skipping
            }
        }
        guard cursor < tokens.count else { return nil }
        var value: Double
        var end: Int
        if let (found, used) = number(in: tokens, at: cursor) {
            value = found
            end = cursor + used
        } else if unit == .chapter, case let .word(word) = tokens[cursor], let roman = romanNumber(word) {
            value = roman
            end = cursor + 1
        } else {
            return nil
        }
        if end + 1 < tokens.count, case let .symbol(dash) = tokens[end], dash == "-" || dash == "\u{2013}", case .number = tokens[end + 1] { return nil }
        return LiveSessionPlace(unit: unit, value: value).map { ($0, end) }
    }

    private static func percentMarkerLength(_ tokens: [Token], at index: Int) -> Int {
        if case .symbol = tokens[index] { return 1 }
        if case let .word(word) = tokens[index], percentWords.contains(word) { return 1 }
        return 2
    }

    private static func isPercentMarker(_ tokens: [Token], at index: Int) -> Bool {
        guard index < tokens.count else { return false }
        if case .symbol("%") = tokens[index] { return true }
        guard case let .word(word) = tokens[index] else { return false }
        if percentWords.contains(word) { return true }
        guard index + 1 < tokens.count, case let .word(second) = tokens[index + 1] else { return false }
        return percentPairs.contains { $0 == [word, second] }
    }
}

/// What the listener typed for "where are you?", read into its parts (#2707): the clock field and the chapter-or-page
/// field are two fields, but "page 40" typed into the clock field, or "12:30" into the other, still means what it says.
public struct LiveSessionWhere: Equatable, Sendable {
    /// The clock position, for a session that has one.
    public var positionMs: Int?
    /// A page, percent or chapter, when the words were readable as one.
    public var place: LiveSessionPlace?
    /// What is kept as the listener's words: the place's label when one was read, else what they typed.
    public var text: String?

    /// `defaultUnit` is what a bare number means in the chapter-or-page field: the kind's usual unit, or, when ending,
    /// the unit the session started in ("140" after starting at page 100 is a page).
    public static func interpret(
        clockText: String, whereText: String, kind: ElsewhereKind, defaultUnit: LiveSessionPlace.Unit? = nil
    ) -> LiveSessionWhere {
        var result = LiveSessionWhere()
        // A paper book has no clock.
        if kind != .paper {
            if let ms = LiveSessionPositionMap.parse(clockText) {
                result.positionMs = ms
            } else if let place = LiveSessionPlace.parseWhole(clockText, defaultUnit: .page, allowsTime: false) {
                result.place = place
            }
        }
        let typed = whereText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let place = LiveSessionPlace.parseWhole(typed, defaultUnit: defaultUnit ?? LiveSessionPlace.defaultUnit(for: kind), allowsTime: false) {
            result.place = place
        }
        result.text = result.place?.sentenceLabel ?? (typed.isEmpty ? nil : typed)
        return result
    }
}
