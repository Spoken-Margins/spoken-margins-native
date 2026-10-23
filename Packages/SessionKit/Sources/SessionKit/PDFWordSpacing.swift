import Foundation

/// Puts back the word spaces a PDF's text layer lost (#2370). Some LaTeX fonts (TeX
/// Gyre Pagella, Type 1) carry no space glyph: a word gap is only a shift in position,
/// and PDFKit misses it on tightly set lines, so "standard tool for describing" comes
/// out "standardtoolfordescribing". Glyph positions don't help (PDFKit's character
/// bounds are spread across the line), so the spacer works on the text alone: hard
/// cues first ("andChen", "Chen,2025", "affect(Webb"), then the letter runs that are
/// not words are split with a word list, preferring the fewest and most common words.
///
/// It only runs on a document that `isGlued` says lost its spaces, so a correctly
/// spaced PDF never changes. Names and jargon not in the list are left whole.
public struct PDFWordSpacer {
    private let lookUp: (String) -> Bool
    private let cache = LookupCache()
    /// How often each word stands alone, spaced, in the document: the word list has no
    /// frequencies, and a word the paper itself prints spaced ("instead", "Autor") is
    /// the likelier reading of a glued run.
    private let documentCounts: [String: Int]
    /// Capitalised names with a capital inside ("GitHub", "OpenAI") that the paper prints
    /// alone at least three times. They stay whole even when each half is a word. Longer
    /// ones are glued title words ("ComparativeAdvantage" in a running head), not names.
    private let printedNames: [[Character]]

    /// `isWord` answers for one lower-case word (the app passes the bundled Kitten
    /// lexicon, `SortedWordList`). Capitalised and upper-case forms are looked up too.
    /// `context` is the document's lines, for `documentCounts`.
    public init(isWord: @escaping (String) -> Bool, context: [String] = []) {
        lookUp = isWord
        var counts: [String: Int] = [:]
        var nameCounts: [String: Int] = [:]
        var brokenBefore = false
        for line in context {
            // The halves of a word broken at a line-end hyphen ("re-" and "cipient") aren't words.
            defer { brokenBefore = line.hasSuffix("-") }
            for (index, token) in line.split(whereSeparator: \.isWhitespace).enumerated() {
                if token.hasSuffix("-") || index == 0 && brokenBefore { continue }
                var word = token.drop { !$0.isLetter }
                while let last = word.last, !last.isLetter { word = word.dropLast() }
                if word.hasSuffix("’s") || word.hasSuffix("'s") { word = word.dropLast(2) }
                guard word.count >= 2 || word == "a" || word == "A" || word == "I", word.allSatisfy(\.isLetter) else { continue }
                counts[Self.key(Array(word)), default: 0] += 1
                if word.first?.isUppercase == true, zip(word, word.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }) {
                    nameCounts[String(word), default: 0] += 1
                }
            }
        }
        documentCounts = counts
        printedNames = nameCounts.filter { $0.value >= 3 && $0.key.count <= 12 }.keys.sorted().map(Array.init)
        tokenCount = max(1_000, Double(counts.values.reduce(0, +)))
    }

    private let tokenCount: Double

    /// Mutable, so one spacer serves one extraction on one thread.
    private final class LookupCache: @unchecked Sendable {
        var words: [String: Bool] = [:]
        var documentWords: [String: Bool] = [:]
        var costs: [String: Double] = [:]
    }

    private func isListed(_ word: String) -> Bool {
        if let known = cache.words[word] { return known }
        let known = lookUp(word)
        cache.words[word] = known
        return known
    }

    /// A letter run this long that is not a word is the sign of a glued line.
    public static let gluedRunLength = 18

    /// Whether the document's text lost its word spaces: at least three lines, and at
    /// least one in a hundred, hold a long letter run that splits cleanly into words.
    public func isGlued(_ lines: [String]) -> Bool {
        let nonEmpty = lines.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        var glued = 0
        for line in nonEmpty where looksGlued(line) {
            glued += 1
            if glued >= 3 && glued * 100 >= nonEmpty.count { return true }
        }
        return false
    }

    /// Whether this line holds a run of `gluedRunLength` or more lower-case letters that
    /// is not a word and splits into three or more listed words, one of them common:
    /// glued prose has "for" and "the"; a primer ("AAGCTTGGCTGATG") or a chemical
    /// ("tetramethylbenzidine") doesn't.
    public func looksGlued(_ line: String) -> Bool {
        let characters = Array(line)
        var start = 0
        while start < characters.count {
            guard characters[start].isLetter else { start += 1; continue }
            var end = start
            while end < characters.count, characters[end].isLetter { end += 1 }
            // An e-mail address or URL slug is not glued prose.
            if end - start >= Self.gluedRunLength, !isInAddress(characters, start..<end) {
                // Hard case cues first, as `respaced` does: "occupationsAIislikely".
                for piece in caseRuns(characters, start..<end) where piece.count >= Self.gluedRunLength {
                    let run = Array(characters[piece])
                    guard run.dropFirst().allSatisfy(\.isLowercase), !isWord(run),
                          let pieces = segmentation(run), pieces.count >= 3 else { continue }
                    let words = pieces.map { Array(run[$0]) }
                    if words.allSatisfy(isWord), words.contains(where: { Self.commonWords.contains(Self.key($0)) }) {
                        return true
                    }
                }
            }
            start = end
        }
        return false
    }

    private func isInAddress(_ characters: [Character], _ run: Range<Int>) -> Bool {
        var tokenStart = run.lowerBound, tokenEnd = run.upperBound
        while tokenStart > 0, !characters[tokenStart - 1].isWhitespace { tokenStart -= 1 }
        while tokenEnd < characters.count, !characters[tokenEnd].isWhitespace { tokenEnd += 1 }
        return Self.isAddressLike(String(characters[tokenStart..<tokenEnd]))
    }

    /// The line with its word spaces put back.
    public func respaced(_ line: String) -> String {
        Self.applying(spaceInsertions(in: line), to: line)
    }

    /// Character offsets of `line` that a space goes in front of. Offsets inside or in
    /// front of a `protected` range (a superscript marker, "economy¹") are never used;
    /// the offset just after one is, when a letter follows it. A word broken by a line-end
    /// hyphen is split whole: `carried` is its start on the line before ("Nev" of "Nev-",
    /// so "ertheless" isn't "er the less"), `continued` its end on the next ("tised" of "adver-").
    public func spaceInsertions(in line: String, protected: [Range<Int>] = [], carried: String = "", continued: String = "") -> [Int] {
        let characters = Array(line)
        var insertions = Set<Int>()
        func isProtected(_ offset: Int) -> Bool {
            protected.contains { $0.lowerBound <= offset && offset < $0.upperBound }
        }
        var tokenStart = 0
        while tokenStart < characters.count {
            guard !characters[tokenStart].isWhitespace else { tokenStart += 1; continue }
            var tokenEnd = tokenStart
            while tokenEnd < characters.count, !characters[tokenEnd].isWhitespace { tokenEnd += 1 }
            defer { tokenStart = tokenEnd }
            let token = tokenStart..<tokenEnd
            guard !Self.isAddressLike(String(characters[token])) else { continue }
            // A species after its genus initial ("B. vallismortis", "R. prolixus") is a name.
            let afterGenus = tokenStart >= 3 && characters[tokenStart - 1] == " " && characters[tokenStart - 2] == "."
                && characters[tokenStart - 3].isUppercase && (tokenStart == 3 || !characters[tokenStart - 4].isLetter)
                && characters[tokenStart].isLowercase && tokenEnd - tokenStart < Self.gluedRunLength
            for offset in hardCueOffsets(characters, token) { insertions.insert(offset) }
            for range in protected where range.upperBound < tokenEnd && range.upperBound > tokenStart
                && characters[range.upperBound].isLetter {
                insertions.insert(range.upperBound)
            }
            // The letter runs left between cues, split with the word list.
            var bounds = insertions.filter { token.contains($0) }.sorted()
            bounds.insert(tokenStart, at: 0)
            bounds.append(tokenEnd)
            for (lower, upper) in zip(bounds, bounds.dropFirst()) {
                var start = lower
                while start < upper {
                    guard characters[start].isLetter else { start += 1; continue }
                    var end = start
                    while end < upper, characters[end].isLetter || isInnerApostrophe(characters, end, upper) { end += 1 }
                    if end == characters.count - 1, characters[end] == "-" {
                        // Without the line after, the broken word's first half is left as it is.
                        let joined = Array(characters[start..<end]) + Array(continued)
                        for offset in continued.isEmpty ? [] : wordOffsets(joined, 0..<joined.count) where offset < end - start {
                            insertions.insert(start + offset)
                        }
                    } else if start == 0, !carried.isEmpty {
                        let joined = Array(carried) + characters[start..<end]
                        for offset in wordOffsets(joined, 0..<joined.count) where offset > carried.count {
                            insertions.insert(offset - carried.count)
                        }
                    } else if !afterGenus {
                        // A run that is the whole token is a word PDFKit spaced itself ("Levanon,").
                        let isWholeToken = characters[token].filter(\.isLetter).count == end - start
                        for offset in wordOffsets(characters, start..<end, wholeToken: isWholeToken) { insertions.insert(offset) }
                    }
                    start = end
                }
            }
        }
        return insertions.filter { !isProtected($0) && $0 > 0 && $0 < characters.count }.sorted()
    }

    /// `line` with a space in front of each offset (offsets are inside tokens, so never
    /// next to a space; `shifted` counts every one).
    public static func applying(_ insertions: [Int], to line: String) -> String {
        guard !insertions.isEmpty else { return line }
        var output = ""
        let marks = Set(insertions)
        for (offset, character) in line.enumerated() {
            if marks.contains(offset) { output.append(" ") }
            output.append(character)
        }
        return output
    }

    /// Moves a character range of the original line onto the respaced line.
    public static func shifted(_ range: Range<Int>, by insertions: [Int]) -> Range<Int> {
        let lower = range.lowerBound + insertions.filter { $0 <= range.lowerBound }.count
        let upper = range.upperBound + insertions.filter { $0 < range.upperBound }.count
        return lower..<max(lower, upper)
    }

    // MARK: - Hard cues

    /// URLs, e-mail addresses, DOIs and identifiers keep their text exactly. A "/" or "="
    /// alone doesn't make one: "Career/TechnicalEducation", "(1/𝜎−1/𝜌)Δlnthe".
    static func isAddressLike(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.contains("://") || lower.contains("www.") || lower.contains("@")
            || lower.contains("\\") || lower.contains("_") || lower.contains("doi:") || lower.hasPrefix("10.")
            || lower.range(of: #"\.(com|org|net|edu|gov|io|ai|uk|de)\b"#, options: .regularExpression) != nil
    }

    private func hardCueOffsets(_ characters: [Character], _ token: Range<Int>) -> [Int] {
        var offsets: [Int] = []
        func letterRun(endingAt index: Int) -> ArraySlice<Character> {
            var start = index
            while start > token.lowerBound, characters[start - 1].isLetter { start -= 1 }
            return characters[start...index]
        }
        func letterRunLength(startingAt index: Int) -> Int {
            var end = index
            while end < token.upperBound, characters[end].isLetter { end += 1 }
            return end - index
        }
        // "Kwaetal.," is "Kwa et al.,".
        var etAl = token.lowerBound + 2
        while etAl + 4 <= token.upperBound {
            // "nonmetal" and "Sheetal" stay whole: glued "et al." keeps its full stop.
            if String(characters[etAl..<(etAl + 4)]) == "etal", characters[etAl - 1].isLetter, characters[etAl - 2].isLetter,
               etAl + 4 < token.upperBound, characters[etAl + 4] == ".", !isWord(Array(letterRun(endingAt: etAl + 3))) {
                offsets.append(etAl)
                offsets.append(etAl + 2)
            }
            etAl += 1
        }
        for index in token.dropFirst() {
            let before = characters[index - 1], here = characters[index]
            let next: Character? = index + 1 < token.upperBound ? characters[index + 1] : nil
            switch (before, here) {
            case let (a, b) where (a == "s" || a == "S") && b.isUppercase && index >= token.lowerBound + 3
                && (characters[index - 2] == "’" || characters[index - 2] == "'") && characters[index - 3].isLetter:
                // A possessive: "occupation’sAI-infeasible", "occupation’sO*NET".
                offsets.append(index)
            case let (a, b) where a.isLowercase && b.isUppercase && startsWord(characters, at: index, in: token):
                // "andChen" and "InProceedings" split; "iPhone", "McDonald", "LaTeX", "PhD",
                // "microRNA" and "circRNAs" keep their case.
                let run = letterRun(endingAt: index - 1)
                let lowerTail = run.reversed().prefix(while: \.isLowercase).count
                let isShortCapitalised = run.first?.isUppercase == true && run.count == lowerTail + 1 && lowerTail <= 2
                // The word since the last capital: "In" of "InProceedings", "Te" of "LaTeX".
                let word = Array(run.suffix(run.count > lowerTail ? lowerTail + 1 : lowerTail))
                // The run before must end in a word: "andChen" splits, "BspizHyb" (a strain) doesn't.
                let endsInWord = (2...min(max(run.count, 2), 12)).contains { run.count >= $0 && isWord(Array(run.suffix($0))) }
                // A name the paper prints alone as one word ("BvalHyb", "GeoHyb") stays whole, unless
                // what comes before is a common word ("andChen").
                var end = index
                while end < token.upperBound, characters[end].isLetter { end += 1 }
                let isPrintedWhole = isDocumentWord(Self.key(Array(characters[(index - run.count)..<end])))
                    && !Self.commonWords.contains(Self.key(word))
                    || isInsidePrintedName(characters, at: index, in: token)
                if !isPrintedWhole, lowerTail >= 2 && !isShortCapitalised && endsInWord || word.count >= 2 && isWord(word) {
                    offsets.append(index)
                }
            case let (a, b) where Self.isMathLetter(a) != Self.isMathLetter(b) && a.isLetter && b.isLetter:
                // Math italic against prose: "𝜌butcanfailwhen𝜌", "𝑡inoccupation".
                offsets.append(index)
            case let (a, b) where (a == "," || a == ";") && (b.isLetter || b == "(" || b == "“"):
                offsets.append(index)
            case let (a, b) where a == "." && (b == "“" || b.isNumber) && index >= token.lowerBound + 3
                && characters[index - 2].isLetter && characters[index - 3].isLetter:
                // "Wang.2026.“Generative" in a reference; "e.g.2" and "v1.2" don't split.
                offsets.append(index)
            case let (a, b) where a == "." && b == "“" && index >= token.lowerBound + 2 && characters[index - 2].isNumber:
                offsets.append(index)
            case let (a, b) where (a == "," || a == ";") && b.isNumber && index >= token.lowerBound + 2
                && (characters[index - 2].isLetter || characters[index - 2] == "."):
                // "Chen,2025" and "al.,2025" split; "1,000" doesn't.
                offsets.append(index)
            case let (a, b) where a == ":" && b.isLetter:
                offsets.append(index)
            case let (a, b) where (a == ")" || a == "]") && b.isLetter:
                offsets.append(index)
            case let (a, b) where (a == "”" || a == "\"") && b.isLetter && index >= token.lowerBound + 2
                && (characters[index - 2].isLetter || ".,!?".contains(characters[index - 2])):
                // A closing quote: "Work.”InProceedings".
                offsets.append(index)
            case let (a, b) where a == "." && b == "(":
                offsets.append(index)
            case let (a, b) where a == "." && b.isUppercase && next?.isLowercase == true:
                // "affect.The" splits; "U.S." and "e.g." don't.
                if index - 2 >= token.lowerBound, characters[index - 2].isLetter, letterRun(endingAt: index - 2).count >= 2 {
                    offsets.append(index)
                }
            case let (a, b) where b == "(" && a.isLetter:
                // "affect(Webb" splits; "f(x)" and "Author(s)" don't.
                var close = index + 1
                while close < token.upperBound, characters[close].isLetter { close += 1 }
                let isSuffix = close < token.upperBound && characters[close] == ")" && close - index - 1 <= 2
                if letterRun(endingAt: index - 1).count >= 2, !isSuffix { offsets.append(index) }
            case let (a, b) where a.isLetter && b.isNumber:
                // "and2025" and "Table1" split; "x1", "CO2", "OAα1" and "circ0051246" don't.
                let run = Array(letterRun(endingAt: index - 1))
                if run.count >= 3, run.contains(where: \.isLowercase), isWord(run) {
                    offsets.append(index)
                }
            case let (a, b) where a.isNumber && b.isLetter:
                // "2019Baumol" and "1992and" split; "2026a", "20th", "10ms" don't.
                let length = letterRunLength(startingAt: index)
                // Capitals start a word ("Baumol") or follow a year ("1992AER"): "H2SO4" stays whole.
                var digits = index
                while digits > token.lowerBound, characters[digits - 1].isNumber { digits -= 1 }
                let isWordStart = next?.isLowercase == true || index - digits == 4
                if b.isUppercase ? length >= 2 && isWordStart : length >= 3 && !Self.unitWords.contains(String(characters[index..<(index + length)]).lowercased()) {
                    offsets.append(index)
                }
            default:
                break
            }
        }
        // A printed name ends where a word starts: "OpenAIand", "GitHubusers"; "DeepMinds" stays.
        for name in printedNames where name.count <= token.count {
            for start in token.lowerBound...(token.upperBound - name.count) where characters[start..<(start + name.count)].elementsEqual(name) {
                let end = start + name.count
                let after = letterRunLength(startingAt: end)
                if after >= 2, (2...min(after, 12)).contains(where: { isWord(Array(characters[end..<(end + $0)])) }) {
                    offsets.append(end)
                }
            }
        }
        return Array(Set(offsets)).sorted()
    }

    /// The capital at `index` starts a capitalised word ("Chen"), or an acronym after
    /// lower case that ends in a word ("forAI-infeasible", "occupationsAIislikely",
    /// "toO*NET"), but not an acronym in a term ("lncRNAs", "miRNA") or one the paper
    /// prints alone ("microRNA").
    private func startsWord(_ characters: [Character], at index: Int, in token: Range<Int>) -> Bool {
        var next = index + 1
        guard next < token.upperBound else { return false }
        if characters[next].isLowercase { return true }
        var start = index
        while start > token.lowerBound, characters[start - 1].isLowercase { start -= 1 }
        // The word before may be capitalised: "GenerativeAIandthe".
        if start > token.lowerBound, characters[start - 1].isUppercase { start -= 1 }
        let before = Array(characters[start..<index])
        guard before.count >= 2, (2...min(before.count, 12)).contains(where: { isWord(Array(before.suffix($0))) }) else { return false }
        if characters[start].isUppercase { start += 1 }
        if characters[next] == "*" || characters[next] == "&" { return true }
        while next < token.upperBound, characters[next].isUppercase { next += 1 }
        guard next - index >= 2 else { return false }
        var lower = 0
        while next + lower < token.upperBound, characters[next + lower].isLowercase { lower += 1 }
        let term = Self.key(Array(characters[start..<(next + min(lower, 1))]))
        return (documentCounts[term] ?? 0) < 2
    }

    /// A letter from Unicode's mathematical alphanumerics (𝜌, 𝐸, 𝑡), which LaTeX math sets.
    static func isMathLetter(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x1D400...0x1D7FF).contains($0.value) } ?? false
    }

    private static let unitWords: Set<String> = [
        "min", "mins", "sec", "secs", "hrs", "khz", "mhz", "ghz", "kbps", "mbps", "gbps", "mph", "kph", "bpm", "rpm",
        "nm", "mm", "cm", "km", "mg", "kg", "ml", "th", "st", "nd", "rd", "pts", "px"
    ]

    private func isInnerApostrophe(_ characters: [Character], _ index: Int, _ upper: Int) -> Bool {
        (characters[index] == "'" || characters[index] == "’") && index > 0 && characters[index - 1].isLetter
            && index + 1 < upper && characters[index + 1].isLetter
    }

    /// Splits a run at its case changes that are hard cues ("occupationsAI"), so the
    /// glued test sees the same pieces `respaced` splits with the word list.
    private func caseRuns(_ characters: [Character], _ run: Range<Int>) -> [Range<Int>] {
        let cuts = hardCueOffsets(characters, run)
        var pieces: [Range<Int>] = []
        var start = run.lowerBound
        for cut in cuts { pieces.append(start..<cut); start = cut }
        pieces.append(start..<run.upperBound)
        return pieces
    }

    // MARK: - Word list

    /// Offsets inside one letter run where the word list puts a space.
    private func wordOffsets(_ characters: [Character], _ run: Range<Int>, wholeToken: Bool = false) -> [Int] {
        let letters = Array(characters[run])
        // An acronym's plural ("RNAs", "PDFs") is one word.
        let isAcronymPlural = letters.count >= 3 && letters.last == "s" && isAcronym(Array(letters.dropLast()))
        guard letters.count >= 2, !isWord(letters), !isAcronym(letters), !isAcronymPlural,
              !(wholeToken && isDocumentWord(Self.key(letters))),
              let pieces = segmentation(letters), pieces.count >= 2 else { return [] }
        // A short run that splits into two rare words the paper never prints alone is more
        // likely a term ("vallismortis", "auxetic") than glued prose.
        if pieces.count == 2, letters.count <= 12, pieces.allSatisfy({ piece in
            let key = Self.key(Array(letters[piece]))
            return !Self.commonWords.contains(key) && documentCounts[key] == nil
        }) {
            return []
        }
        // A capitalised word ("Goldfarb", "Tonetti") is most likely a name: split it only
        // into known words, one of them common ("Theresults"), unless the run is long. A
        // two-letter common word counts first before longer or common words ("Inthe",
        // "Inaddition") or, inside a glued token, after longer words ("theValueofWork"),
        // so "Daron", "Atalay" and "Levanon" stay whole.
        let isCapitalised = letters.first?.isUppercase == true && letters.dropFirst().allSatisfy { !$0.isUppercase }
        if isCapitalised, letters.count < 14 {
            let words = pieces.map { Array(letters[$0]) }
            let allKnown = words.allSatisfy { isWord($0) || isDocumentWord(Self.key($0)) }
            let hasCommon = words.enumerated().contains { index, word in
                Self.commonWords.contains(Self.key(word)) && (word.count >= 3
                    || index == 0 && word.count == 2 && words.dropFirst().allSatisfy { Self.commonWords.contains(Self.key($0)) || $0.count >= 5 }
                    || !wholeToken && words.allSatisfy { $0 == word || $0.count >= 4 })
            }
            guard allKnown, hasCommon else { return [] }
        }
        return pieces.dropFirst().map { run.lowerBound + $0.lowerBound }
    }

    /// The cheapest split of `letters` into words, or nil when keeping it whole is cheapest.
    func segmentation(_ letters: [Character]) -> [Range<Int>]? {
        let count = letters.count
        guard count >= 2 else { return nil }
        let maxPiece = 24
        var best = [Double](repeating: .infinity, count: count + 1)
        var back = [Int](repeating: -1, count: count + 1)
        best[0] = 0
        let cases = Cases(letters)
        for end in 1...count {
            for start in max(0, end - maxPiece)..<end where best[start] < .infinity {
                let cost = best[start] + pieceCost(letters, start..<end, cases)
                if cost < best[end] { best[end] = cost; back[end] = start }
            }
        }
        var pieces: [Range<Int>] = []
        var end = count
        while end > 0 {
            let start = back[end]
            guard start >= 0 else { return nil }
            pieces.insert(start..<end, at: 0)
            end = start
        }
        guard pieces.count >= 2, best[count] < unknownCost(count) else { return nil }
        return pieces
    }

    /// Each letter's case, worked out once per run: the segmentation asks for every piece.
    private struct Cases {
        let isLetter: [Bool], isUpper: [Bool], isLower: [Bool]

        init(_ letters: [Character]) {
            isLetter = letters.map(\.isLetter)
            isUpper = letters.map(\.isUppercase)
            isLower = letters.map(\.isLowercase)
        }
    }

    private func pieceCost(_ letters: [Character], _ range: Range<Int>, _ cases: Cases) -> Double {
        // Case must read as one word: lower case, upper case, or capitalised at the
        // start of the run or after an upper-case piece ("AIis", "PDFThe").
        guard cases.isLetter[range.lowerBound] else { return .infinity }
        let cased = range.filter { cases.isLetter[$0] }
        let isLower = cased.allSatisfy { cases.isLower[$0] }
        let isUpper = cased.allSatisfy { cases.isUpper[$0] }
        let isCapitalised = cases.isUpper[range.lowerBound] && cased.dropFirst().allSatisfy { cases.isLower[$0] }
        let afterUpper = range.lowerBound == 0 || cases.isUpper[range.lowerBound - 1]
        // A case change the hard cues kept ("lncRNA", "microRNA") isn't a word break either.
        let afterLower = range.lowerBound > 0 && cases.isLower[range.lowerBound - 1]
        // A term of lower case then capitals ("lncRNAs", "miRNA") is one piece.
        let firstUpper = cased.firstIndex { cases.isUpper[$0] } ?? cased.count
        let tail = cased[firstUpper...].filter { !cases.isUpper[$0] }
        let isTerm = !afterLower && firstUpper > 0 && cases.isLower[cased[0]] && cased.count - firstUpper - tail.count >= 2
            && cased[..<firstUpper].allSatisfy { cases.isLower[$0] } && (tail.isEmpty || tail == [cased.last!] && letters[cased.last!] == "s")
        if isTerm {
            let printed = String(letters[range])
            let seen = Double(documentCounts[Self.key(Array(letters[range]))] ?? 0)
            return seen >= 2 ? log2(tokenCount / seen) : unknownCost(printed.count)
        }
        // An acronym's plural or possessive ("MWDs", "BGI’s") is one piece, so
        // "theMWDsinthesample" isn't "MWD sin".
        if range.count >= 3, !afterLower, letters[range.upperBound - 1] == "s",
           cased.dropLast().allSatisfy({ cases.isUpper[$0] }) {
            let stem = Array(letters[range.dropLast()])
            return wordCost(stem.last == "’" || stem.last == "'" ? Array(stem.dropLast()) : stem, isLower: false, isUpper: true)
        }
        guard isLower || isUpper && !afterLower || (isCapitalised && afterUpper) else { return .infinity }
        // "A" or "I" cut from an acronym ("AI" as "A I") isn't a word.
        if range.count == 1, isUpper, range.lowerBound > 0 && cases.isUpper[range.lowerBound - 1]
            || range.upperBound < letters.count && cases.isUpper[range.upperBound] {
            return .infinity
        }
        // Nor is a lone lower-case letter after capitals: "GPa", "kPa".
        if range.count == 1, isLower, range.lowerBound > 0, cases.isUpper[range.lowerBound - 1] { return .infinity }
        let printed = String(letters[range])
        if let known = cache.costs[printed] { return known }
        let cost = wordCost(Array(letters[range]), isLower: isLower, isUpper: isUpper)
        cache.costs[printed] = cost
        return cost
    }

    private func wordCost(_ piece: [Character], isLower: Bool, isUpper: Bool) -> Double {
        // A unigram cost, log2(tokens / expected count): the count is how often the paper
        // prints the word alone, plus a prior rate from the word list for words it never does.
        let key = Self.key(piece)
        // A possessive ("recipient’s") counts its stem's uses, as `documentCounts` does.
        let countKey = possessiveStem(piece).map { Self.key($0) } ?? key
        let seen = Double(isLower && isGluedFragment(key) ? 0 : documentCounts[countKey] ?? 0)
        func cost(rate: Double) -> Double { log2(tokenCount / (seen + tokenCount * rate)) }
        if isUpper, piece.count >= 2 {
            guard isAcronym(piece) else { return .infinity }
            return cost(rate: isWord(piece) ? 1e-5 : 4e-6)
        }
        if isWord(piece) {
            if Self.commonWords.contains(key) { return cost(rate: 6e-3) }
            // Short rare entries ("ratu", "res", "qua dru") lose to one longer word, even unknown,
            // and a form the list only implies ("rematched") to one it lists ("are matched").
            let implied = !isListed(key) && piece.count >= 5
            return cost(rate: piece.count == 3 ? 5e-7 : piece.count == 4 ? 2e-6 : implied ? 4e-6 : 1e-5)
        }
        if let stem = possessiveStem(piece) {
            let stemKey = Self.key(stem)
            if isWord(stem) || isDocumentWord(stemKey) {
                return log2(tokenCount / (Double(documentCounts[stemKey] ?? 0) + tokenCount * 1e-5))
            }
        }
        // A name or term the list lacks but the paper prints alone at least three times.
        if isDocumentWord(key) { return cost(rate: 0) }
        return unknownCost(piece.count)
    }

    /// A short entry that is two common words run together ("ison", "isa"): its count
    /// in a glued document comes from glued text, not from the word.
    private func isGluedFragment(_ key: String) -> Bool {
        guard key.count >= 3, key.count <= 6, !Self.commonWords.contains(key) else { return false }
        return (1..<key.count).contains { cut in
            Self.commonWords.contains(String(key.prefix(cut))) && Self.commonWords.contains(String(key.dropFirst(cut)))
        }
    }

    /// Whether `index` falls inside one of `printedNames`, as "OpenAI" in "datafromOpenAIand".
    private func isInsidePrintedName(_ characters: [Character], at index: Int, in token: Range<Int>) -> Bool {
        printedNames.contains { name in
            let first = max(token.lowerBound, index - name.count + 1)
            let last = min(index - 1, token.upperBound - name.count)
            guard first <= last else { return false }
            return (first...last).contains { characters[$0..<($0 + name.count)].elementsEqual(name) }
        }
    }

    /// Printed alone at least three times, and not just a glued run the paper repeats
    /// ("bottleneckpressure"): it doesn't split wholly into listed words.
    private func isDocumentWord(_ key: String) -> Bool {
        guard key.count >= 3, (documentCounts[key] ?? 0) >= 3 else { return false }
        if let known = cache.documentWords[key] { return known }
        let letters = Array(key)
        var covered = [Bool](repeating: false, count: letters.count + 1)
        covered[0] = true
        for end in 1...letters.count {
            // Pieces of three or more letters: "infeasible" isn't "in feasible", nor "prolixus" "prolix us".
            for start in max(0, end - 24)..<end where covered[start] && end - start < letters.count && end - start >= 3 {
                if isWord(Array(letters[start..<end])) { covered[end] = true; break }
            }
        }
        // Nor is a phrase glued the same way every time ("attheendof", eight times in table
        // notes): it splits wholly into common words. "subtilis" ("sub til is") doesn't.
        var phrase = [Bool](repeating: false, count: letters.count + 1)
        phrase[0] = true
        for end in 1...letters.count {
            for start in max(0, end - 12)..<end where phrase[start] && end - start < letters.count {
                if Self.commonWords.contains(String(letters[start..<end])) { phrase[end] = true; break }
            }
        }
        let known = !covered[letters.count] && !phrase[letters.count]
        cache.documentWords[key] = known
        return known
    }

    /// An unknown piece costs more than any listed word, and three more bits a letter (English runs about two), so a
    /// long unknown run reads as several words but a name keeps its pieces' cost above it.
    private func unknownCost(_ length: Int) -> Double {
        // A stray unknown letter or two ("quadruple x") is never a word of glued prose.
        guard length >= 3 else { return .infinity }
        return log2(1e7) + 3 * Double(length)
    }

    /// A listed word with a regular ending the list leaves out: "literatures",
    /// "computerisation" (British "-isation" as "-ization").
    private func isInflected(_ piece: [Character]) -> Bool {
        let key = Self.key(piece)
        guard key.count >= 5, piece.allSatisfy(\.isLetter) else { return false }
        for (suffix, replacements) in Self.endings where key.hasSuffix(suffix) {
            let stem = String(key.dropLast(suffix.count))
            guard stem.count >= 3 else { continue }
            if replacements.contains(where: { isListed(stem + $0) }) { return true }
        }
        return false
    }

    private static let endings: [(String, [String])] = [
        ("isations", ["izations", "ization"]), ("isation", ["ization"]), ("ised", ["ized", "ize"]), ("ising", ["izing", "ize"]),
        ("ises", ["izes", "ize"]), ("ise", ["ize"]), ("bility", ["ble"]), ("ness", [""]), ("ies", ["y"]), ("ied", ["y"]), ("ings", ["ing", ""]), ("ing", ["", "e"]),
        ("es", [""]), ("s", [""]), ("ed", ["", "e"]), ("ly", [""]), ("ers", ["er", "e"]), ("er", ["", "e"])
    ]

    private func possessiveStem(_ piece: [Character]) -> [Character]? {
        guard piece.count >= 3, piece.last == "s" || piece.last == "S",
              piece[piece.count - 2] == "'" || piece[piece.count - 2] == "’" else { return nil }
        return Array(piece.dropLast(2))
    }

    private func isAcronym(_ piece: [Character]) -> Bool {
        piece.count >= 2 && piece.count <= 8 && piece.allSatisfy(\.isUppercase)
    }

    /// Listed, with one- and two-letter entries limited to real English words: the
    /// lexicon also lists letters and abbreviations ("b", "ek", "ou").
    func isWord(_ piece: [Character]) -> Bool {
        let key = Self.key(piece)
        guard !key.isEmpty else { return false }
        if key.count <= 2 {
            if key == "i" { return piece == ["I"] }
            return Self.shortWords.contains(key)
        }
        if isListed(key) { return true }
        if key.count >= 5, isInflected(piece) { return true }
        // A capitalised or upper-case entry ("Chen", "AI"): look it up as printed too.
        let printed = String(piece).precomposedStringWithCompatibilityMapping
        return printed != key && isListed(printed)
    }

    /// Lower case with ligatures unfolded ("ﬁnd" → "find") and curly apostrophes straightened.
    static func key(_ piece: [Character]) -> String {
        if piece.allSatisfy(\.isASCII) { return String(piece).lowercased() }
        return String(piece).precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    private static let shortWords: Set<String> = [
        "a", "i", "am", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it", "me", "my",
        "no", "of", "oh", "on", "or", "ox", "so", "to", "up", "us", "we", "vs"
    ]

    /// The commonest English words, which win ties ("is the" over "ist he").
    static let commonWords: Set<String> = [
        "a", "about", "above", "across", "after", "again", "against", "all", "almost", "along", "already", "also",
        "although", "always", "among", "an", "and", "another", "any", "are", "around", "as", "at", "away", "back",
        "be", "because", "become", "been", "before", "being", "below", "best", "better", "between", "both", "but",
        "by", "can", "cannot", "case", "could", "data", "did", "do", "does", "done", "down", "during", "each",
        "early", "either", "end", "enough", "even", "every", "example", "fact", "far", "few", "first", "for",
        "found", "from", "full", "further", "general", "get", "given", "go", "good", "great", "had", "has", "have",
        "he", "her", "here", "high", "him", "his", "how", "however", "i", "if", "important", "in", "into", "is",
        "it", "its", "itself", "just", "know", "large", "last", "least", "less", "level", "like", "long", "low",
        "made", "make", "many", "may", "me", "might", "more", "most", "much", "must", "my", "need", "never", "new",
        "next", "no", "not", "now", "number", "of", "off", "often", "on", "once", "one", "only", "or", "order",
        "other", "others", "our", "out", "over", "own", "part", "people", "per", "place", "point", "rather",
        "same", "see", "set", "several", "share", "she", "should", "show", "shows", "since", "small", "so", "some",
        "something", "still", "such", "take", "than", "that", "the", "their", "them", "themselves", "then",
        "there", "therefore", "these", "they", "this", "those", "though", "three", "through", "thus", "time", "to",
        "too", "toward", "two", "under", "until", "up", "upon", "us", "use", "used", "using", "very", "was", "way",
        "we", "well", "were", "what", "when", "where", "whether", "which", "while", "who", "whose", "why", "will",
        "with", "within", "without", "work", "would", "year", "years", "yet", "you", "your"
    ]
}

/// A sorted word list read in place: one `word` or `word<TAB>anything` line per entry,
/// sorted by the word's UTF-8 bytes, as the bundled Kitten lexicon is. The file is
/// memory-mapped and binary-searched, so it never becomes a set in memory.
public final class SortedWordList: @unchecked Sendable {
    private let data: Data

    public init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }

    public func contains(_ word: String) -> Bool {
        let key = Array(word.utf8)
        guard !key.isEmpty else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            let newline = UInt8(ascii: "\n"), tab = UInt8(ascii: "\t")
            var low = 0, high = bytes.count
            while low < high {
                let middle = low + (high - low) / 2
                var lineStart = middle
                while lineStart > low, bytes[lineStart - 1] != newline { lineStart -= 1 }
                var lineEnd = middle
                while lineEnd < bytes.count, bytes[lineEnd] != newline { lineEnd += 1 }
                var keyEnd = lineStart
                while keyEnd < lineEnd, bytes[keyEnd] != tab { keyEnd += 1 }
                var index = lineStart, other = 0
                var order = ComparisonResult.orderedSame
                while index < keyEnd, other < key.count {
                    if bytes[index] != key[other] { order = bytes[index] < key[other] ? .orderedAscending : .orderedDescending; break }
                    index += 1
                    other += 1
                }
                if order == .orderedSame, !(index == keyEnd && other == key.count) {
                    order = index == keyEnd ? .orderedAscending : .orderedDescending
                }
                switch order {
                case .orderedSame: return true
                case .orderedAscending: low = lineEnd + 1
                case .orderedDescending: high = lineStart
                }
            }
            return false
        }
    }
}
