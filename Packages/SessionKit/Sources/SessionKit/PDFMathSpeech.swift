import Foundation

/// What a voice hears for math in a PDF.
///
/// Many PDFs store math as Unicode math letters ("𝐴", "𝛼") or private-use glyphs. Neural voices have no tokens for
/// them: Phonon feeds them to its model as raw bytes, and the model fills the time with noise the owner called a
/// ghost. So no such character reaches a voice. A line that is a display equation becomes one "Equation not read."
/// notice, and math inside a sentence is said in words ("g L over 3"), or as "formula" when it's too long to follow.
///
/// This runs on the stored text when speech is planned, so it needs no new import and moves no anchor: every spoken
/// character keeps the offset of the source character it stands for. It uses text alone, because stored documents
/// keep no fonts or positions.
public enum PDFMathSpeech {
    /// Inline math longer than this many spoken symbols is said as "formula".
    static let spokenSymbolBudget = 8
    static let formulaWord = "formula"

    private enum Kind: Equatable {
        /// A symbol, said as this word.
        case symbol(String)
        /// A Unicode math operator, said as this word (empty: silent).
        case mathOperator(String)
        /// A combining mark standing alone, or a private-use glyph: never spoken.
        case junk
        case other
    }

    private static let operators: [Character: String] = [
        "≡": "equals", "≈": "approximately", "≃": "approximately", "≅": "approximately", "≠": "not equal to",
        "≤": "less than or equal to", "≥": "greater than or equal to", "≦": "less than or equal to", "≧": "greater than or equal to",
        "⩽": "less than or equal to", "⩾": "greater than or equal to", "≪": "much less than", "≫": "much greater than",
        "−": "minus", "∓": "minus or plus", "±": "plus or minus", "×": "times", "÷": "over", "∕": "over",
        "⋅": "", "∘": "", "∙": "", "→": "to", "⟶": "to", "↦": "to", "←": "from", "⟹": "implies", "⇒": "implies", "⟺": "if and only if",
        "⇔": "if and only if", "∈": "in", "∉": "not in", "∝": "proportional to", "∼": "similar to", "∞": "infinity",
        "∂": "partial", "∇": "gradient", "∑": "sum", "∏": "product", "∫": "integral", "√": "root of", "′": "prime", "″": "double prime",
        "∀": "for all", "∃": "there exists", "⊂": "subset of", "⊆": "subset of", "∩": "intersect", "∪": "union", "∅": "empty set",
        "∧": "and", "∨": "or", "¬": "not", "⊗": "tensor", "⊕": "plus", "⟨": "", "⟩": "", "‖": "", "∣": "", "⋯": "", "⋱": "", "⋮": "", "∗": "star",
    ]

    /// Said in Greek letter names; Phonon knows these words in plain text but not in the math alphabet.
    private static let greekNames: [Character: String] = {
        let names = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi",
                     "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega"]
        var result: [Character: String] = ["ς": "sigma", "ϵ": "epsilon", "ϑ": "theta", "ϕ": "phi", "ϱ": "rho", "ϖ": "pi", "ϰ": "kappa"]
        let lower = Array("αβγδεζηθικλμνξοπρστυφχψω")
        let upper = Array("ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ")
        for (index, name) in names.enumerated() {
            result[lower[index]] = name
            result[upper[index]] = name
        }
        return result
    }()

    private static func folded(_ scalar: Unicode.Scalar) -> Kind? {
        let plain = String(scalar).precomposedStringWithCompatibilityMapping
        guard plain.count == 1, let letter = plain.first else { return nil }
        if let greek = greekNames[letter] { return .symbol(greek) }
        // A capital is said as the letter. A lone lower-case "s" or "a" is dropped or read as a word (measured on Phonon).
        if letter.isASCII, letter.isLetter { return .symbol(letter.uppercased()) }
        if letter.isASCII, letter.isNumber { return .symbol(String(letter)) }
        return nil
    }

    private static func kind(of character: Character) -> Kind {
        guard let scalar = character.unicodeScalars.first else { return .other }
        // "t̄": a mark that composes with nothing is math notation, and the voice has no token for it.
        if character.unicodeScalars.count > 1, scalar.isASCII, scalar.properties.isAlphabetic,
           character.unicodeScalars.dropFirst().contains(where: { (0x0300...0x036F).contains($0.value) }),
           String(character).precomposedStringWithCanonicalMapping.unicodeScalars.count > 1 {
            return .symbol(String(character.unicodeScalars.first!).uppercased())
        }
        switch scalar.value {
        case 0x1D400...0x1D7FF:
            return folded(scalar) ?? .junk
        case 0x210A...0x2113, 0x2102, 0x2115, 0x2119...0x211D, 0x2124, 0x2128, 0x212C, 0x212D, 0x212F...0x2131, 0x2133...0x2139:
            return folded(scalar) ?? .other
        case 0xE000...0xF8FF:
            return .junk
        case 0x0300...0x036F:
            return .junk
        default:
            break
        }
        if let word = operators[character] { return .mathOperator(word) }
        return .other
    }

    private static func isMathStarter(_ character: Character) -> Bool {
        kind(of: character) != .other
    }

    /// Whether `text` holds a character no voice should be handed. Plain text skips all of this.
    static func containsMathAlphabet(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x1D400...0x1D7FF).contains($0.value) || (0xE000...0xF8FF).contains($0.value) || (0x0300...0x036F).contains($0.value)
        }
    }

    // MARK: - The last check before a voice

    private static let unspokenMarks = Set("ˆ¯˜˘´˚˙¨ˇ¸∥®™†‡§·")
    private static let namedSymbols: [Character: String] = ["∆": "delta", "Ω": "omega", "µ": "mu"]

    /// `text` with nothing left that Phonon would feed its model as raw bytes: ligatures opened, accents folded,
    /// stray marks dropped. Only the audio is affected; plans and anchors keep the text as it was.
    public static func voiceSafe(_ text: String) -> String {
        let characters = Array(text)
        let spoken = speakingInlineMath(characters, offsets: Array(characters.indices)).characters
        var output = ""
        output.reserveCapacity(spoken.count)
        for character in spoken {
            if character.isASCII {
                output.append(character)
            } else if unspokenMarks.contains(character) {
                continue
            } else if let name = namedSymbols[character] ?? greekNames[character] {
                if output.last?.isLetter == true || output.last?.isNumber == true { output.append(" ") }
                output += name
            } else if character.isLetter {
                let plain = String(character).precomposedStringWithCompatibilityMapping
                    .folding(options: .diacriticInsensitive, locale: nil)
                output += plain
            } else {
                output.append(character)
            }
        }
        return output
    }

    // MARK: - Footnotes in the body

    /// Where a block of footnotes starts in a body segment that runs up to a page break, or nil. Older imports stored
    /// footnotes as body when the page had no detectable superscript markers; "1Sandberg (2013) presented…" gives
    /// them away, a number glued to a capitalized word at the start of a line.
    static func footnoteBlockStart(in characters: [Character], range: Range<Int>, endsAtPageBreak: Bool) -> Int? {
        guard endsAtPageBreak else { return nil }
        var lineStart = range.lowerBound
        var lines = 0
        var found: Int?
        var index = range.lowerBound
        while index <= range.upperBound {
            if index == range.upperBound || characters[index] == "\n" {
                lines += 1
                if found == nil, isGluedFootnote(characters[lineStart..<index]) {
                    found = lineStart
                    lines = 1
                }
                lineStart = index + 1
            }
            index += 1
        }
        // A real footnote block is the page's tail, not most of a long segment.
        guard let found, lines <= maxFootnoteBlockLines else { return nil }
        return found
    }

    static let maxFootnoteBlockLines = 24

    private static func isGluedFootnote(_ line: ArraySlice<Character>) -> Bool {
        var position = line.startIndex
        var digits = 0
        while position < line.endIndex, line[position].isASCII, line[position].isNumber, digits < 3 {
            position += 1
            digits += 1
        }
        guard (1...2).contains(digits), position + 2 < line.endIndex else { return false }
        return line[position].isUppercase && line[position + 1].isLowercase
    }

    // MARK: - Display equations

    private struct LineFacts {
        var tokens: Int
        var strong: Int
        var prose: Int
        var isFragment: Bool
        var isDisplay: Bool
    }

    private static let mathFunctionWords: Set<String> = ["lim", "log", "exp", "max", "min", "sin", "cos", "tan", "sup", "inf", "det", "arg", "mod", "var", "cov", "argmax", "argmin", "sgn", "diag", "tanh", "sinh", "cosh"]

    private static func facts(_ line: ArraySlice<Character>) -> LineFacts {
        let text = String(line)
        let tokens = text.split(whereSeparator: \.isWhitespace)
        var strong = 0
        for character in line {
            switch kind(of: character) {
            case .symbol, .junk:
                strong += 1
            case .mathOperator(let word):
                if !["minus", "star", ""].contains(word) { strong += 1 }
            case .other:
                if greekNames[character] != nil { strong += 1 }
            }
        }
        var prose = 0
        for token in tokens {
            // Runs of plain lower-case letters: "and" counts in "𝐴and", and a word's capital does not hide it.
            var run = ""
            var longest = ""
            for character in token {
                if character.isASCII, character.isLowercase {
                    run.append(character)
                    if run.count > longest.count { longest = run }
                } else {
                    run = ""
                }
            }
            if longest.count >= 3, !mathFunctionWords.contains(longest) { prose += 1 }
        }
        let numbered = text.range(of: #"\(\s*[0-9]{1,3}[a-z]?\s*\)\s*[.,]?\s*$"#, options: .regularExpression) != nil
        var display = false
        if strong >= 2 || (strong == 1 && (text.contains("=") || numbered)) {
            if prose == 0 {
                display = true
            } else if numbered, prose <= 3 {
                display = true
            } else if prose <= 2, strong >= 4, strong >= prose * 4 {
                display = true
            }
        } else if strong == 0, prose == 0, tokens.count >= 3, text.range(of: "[=<>]", options: .regularExpression) != nil {
            // "Y = AK + BL" in a font with no math letters.
            let short = tokens.filter { $0.count <= 4 }
            display = short.count == tokens.count && tokens.contains { $0.count == 1 && $0.first?.isLetter == true }
        }
        let fragment = prose == 0 && tokens.count <= 3 && line.count <= 14
            && !line.contains { $0.isLetter && $0.isASCII && line.filter(\.isLetter).count >= 3 }
        return LineFacts(tokens: tokens.count, strong: strong, prose: prose, isFragment: fragment, isDisplay: display)
    }

    /// The character ranges of `range` (lines split at "\n") that are display equations and aren't read.
    /// `equationBefore` / `equationAfter`: the document's neighbouring read segment is itself an equation, so a stray
    /// fragment at this segment's edge belongs to it.
    static func displayLines(
        in characters: [Character],
        range: Range<Int>,
        equationBefore: Bool = false,
        equationAfter: Bool = false
    ) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = range.lowerBound
        for index in range where characters[index] == "\n" {
            lines.append(start..<index)
            start = index + 1
        }
        lines.append(start..<range.upperBound)
        var measured = lines.map { facts(characters[$0]) }
        // A fragment ("1", ">", ", (4)", "𝜃") touching a display line is part of it. Works outward until nothing changes.
        var changed = true
        while changed {
            changed = false
            for index in measured.indices where measured[index].isFragment && !measured[index].isDisplay {
                let before = index > 0 ? measured[index - 1].isDisplay : equationBefore
                let after = index + 1 < measured.count ? measured[index + 1].isDisplay : equationAfter
                if before || after {
                    measured[index].isDisplay = true
                    changed = true
                }
            }
        }
        // A stack of symbol fragments, a fraction set line by line, is an equation with nothing else to join.
        var index = 0
        while index < measured.count {
            guard measured[index].isFragment, !measured[index].isDisplay else { index += 1; continue }
            var end = index
            while end + 1 < measured.count, measured[end + 1].isFragment, !measured[end + 1].isDisplay { end += 1 }
            if end - index >= 2, measured[index...end].contains(where: { $0.strong > 0 }) {
                for line in index...end { measured[line].isDisplay = true }
            }
            index = end + 1
        }
        return lines.indices.filter { measured[$0].isDisplay }.map { lines[$0] }
    }

    // MARK: - Inline math

    /// `characters` with inline math said in words, and each new character carrying the offset of what it stands for.
    /// Unchanged when there is no math. Idempotent: the words it writes are plain text.
    public static func speakingInlineMath(_ characters: [Character], offsets: [Int]) -> (characters: [Character], offsets: [Int]) {
        guard characters.contains(where: isMathStarter) else { return (characters, offsets) }
        var output: [Character] = []
        var outputOffsets: [Int] = []
        output.reserveCapacity(characters.count)
        outputOffsets.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            guard isMathStarter(characters[index]) else {
                output.append(characters[index])
                outputOffsets.append(offsets[index])
                index += 1
                continue
            }
            var start = index
            let end = spanEnd(from: index, in: characters)
            // "1/𝜃": the number and slash before the first symbol belong to it.
            var lookback = output.count
            while lookback > 0, output[lookback - 1].isNumber || "/+=<>.".contains(output[lookback - 1]) { lookback -= 1 }
            let absorbs = lookback < output.count && (lookback == 0 || !output[lookback - 1].isLetter)
                && output[lookback..<output.count].contains { "/+=<>".contains($0) || $0.isNumber }
                && output.last.map { $0.isNumber || "/+=<>".contains($0) } == true
            if absorbs {
                let count = output.count - lookback
                start = index - count
                output.removeLast(count)
                outputOffsets.removeLast(count)
            }
            let words = spokenWords(characters[start..<end])
            if !words.isEmpty {
                let text = words.count > spokenSymbolBudget ? formulaWord : words.joined(separator: " ")
                if let last = output.last, last.isLetter || last.isNumber {
                    output.append(" ")
                    outputOffsets.append(offsets[start])
                }
                for character in text {
                    output.append(character)
                    outputOffsets.append(offsets[start])
                }
                if end < characters.count, characters[end].isLetter || characters[end].isNumber {
                    output.append(" ")
                    outputOffsets.append(offsets[max(start, end - 1)])
                }
            }
            index = end
        }
        return (output, outputOffsets)
    }

    /// Where the math starting at `start` ends: through symbols, numbers and brackets that hang together, and across
    /// a space only when math carries on after it.
    private static func spanEnd(from start: Int, in characters: [Character]) -> Int {
        var position = start
        var committed = start + 1
        var depth = 0
        var afterOperator = false
        func isAsciiOperator(_ character: Character) -> Bool { "=+<>/-*^_".contains(character) }
        while position < characters.count {
            let character = characters[position]
            if isMathStarter(character) {
                if case .mathOperator(let word) = kind(of: character), word != "star", word != "prime" { afterOperator = true } else { afterOperator = false }
                position += 1
                committed = position
            } else if character.isNumber {
                position += 1
                committed = position
                afterOperator = false
            } else if character == ".", position + 1 < characters.count, characters[position + 1].isNumber,
                      position > start, characters[position - 1].isNumber {
                position += 1
            } else if isAsciiOperator(character) {
                afterOperator = true
                position += 1
            } else if "([{".contains(character) {
                depth += 1
                position += 1
            } else if ")]}".contains(character) {
                guard depth > 0 else { break }
                depth -= 1
                position += 1
                committed = position
            } else if character == ",", position + 1 < characters.count, characters[position + 1] != " ", !characters[position + 1].isNewline {
                position += 1
            } else if character == " " || character == "\n" {
                guard position + 1 < characters.count else { break }
                let next = characters[position + 1]
                let carriesOn = isMathStarter(next) && !isBareSymbolAfterProse(next)
                    || isAsciiOperator(next) && next != "-" && position + 2 < characters.count && characters[position + 2] == " "
                    || afterOperator && (next.isNumber || next == "(")
                guard carriesOn, character == " " || afterOperator else { break }
                position += 1
            } else {
                break
            }
        }
        return committed
    }

    /// Two bare symbols with only a space between are one expression ("𝐵 𝐿"); nothing to exclude yet, kept as a seam.
    private static func isBareSymbolAfterProse(_ character: Character) -> Bool { false }

    private static func spokenWords(_ span: ArraySlice<Character>) -> [String] {
        var words: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty {
                words.append(number)
                number = ""
            }
        }
        for character in span {
            if character.isNumber || (character == "." && !number.isEmpty) {
                number.append(character)
                continue
            }
            flush()
            switch kind(of: character) {
            case .symbol(let word):
                words.append(word)
            case .mathOperator(let word):
                if !word.isEmpty { words.append(word) }
            case .junk:
                break
            case .other:
                switch character {
                case "=": words.append("equals")
                case "+": words.append("plus")
                case "-": words.append("minus")
                case "<": words.append("less than")
                case ">": words.append("greater than")
                case "/": words.append("over")
                case "*": words.append("star")
                default:
                    if let greek = greekNames[character] { words.append(greek) }
                }
            }
        }
        flush()
        return words
    }
}
