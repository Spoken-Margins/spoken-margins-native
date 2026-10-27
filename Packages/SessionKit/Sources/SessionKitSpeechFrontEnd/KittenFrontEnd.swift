import Foundation

/// Text to Kitten input ids with no GPL code: I14 normalization, then per word the misaki gold
/// dictionary (Apache-2.0), the CMU Pronouncing Dictionary (BSD-style), a split into two dictionary
/// words, and last the neural letter-to-sound net, every pronunciation spelled the way espeak-ng
/// spells it (Kitten was trained on espeak's output; none of its code or data is used).
///
/// A port of `research/C2/frontend/frontend.py`, the reference: `KittenFrontEndTests` reproduces every
/// entry of `test_vectors.json`. Safe to share between threads.
public final class KittenFrontEnd: @unchecked Sendable {
    private let lexicon: PronunciationLexicon
    private let neural: NeuralLetterToSound
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public init(lexiconURL: URL, g2pWeightsURL: URL, g2pManifestURL: URL) throws {
        lexicon = try PronunciationLexicon(contentsOf: lexiconURL)
        neural = try NeuralLetterToSound(weightsURL: g2pWeightsURL, manifestURL: g2pManifestURL)
    }

    /// Kitten's ids for the text: pad, the phoneme characters, an ellipsis, pad.
    public func inputIDs(for text: String) -> [Int64] {
        Self.inputIDs(forPhonemes: phonemize(text))
    }

    // MARK: Words

    static let vowelLetters = Rx("[aeiouyAEIOUY]")
    static let acronym = Rx("[A-Z]{2,5}s?")
    static let shortAcronym = Rx("[A-Z]{2,4}")
    private static let nonLetters = Rx("[^a-z]")
    private static let vowelStart = Rx("^\"?[ˈˌ]?[\(Espeakify.vowels)]")

    func lookup(_ word: String) -> String? {
        lexicon.pronunciation(of: word) ?? lexicon.pronunciation(of: word.lowercased())
    }

    static func isUppercase(_ word: String) -> Bool {
        var cased = false
        for scalar in word.unicodeScalars where scalar.properties.isCased {
            if !scalar.properties.isUppercase { return false }
            cased = true
        }
        return cased
    }

    /// 'PBS' -> three letter names, stress on the last only.
    static func spelled(_ letters: [String]) -> String {
        let names = letters.compactMap { FrontEndTables.letterNames[$0.lowercased()] }
        return names.enumerated().map { index, name in
            index < names.count - 1 ? name.replacingLiteral("ˈ", with: "ˌ") : name
        }.joined()
    }

    public func word(_ word: String) -> String {
        lock.lock()
        if let cached = cache[word] { lock.unlock(); return cached }
        lock.unlock()
        let result = computeWord(word)
        lock.lock()
        if cache.count > 50_000 { cache.removeAll() }
        cache[word] = result
        lock.unlock()
        return result
    }

    func computeWord(_ w: String) -> String {
        let lower = w.lowercased()
        if let spoken = FrontEndTables.numberWords[lower] { return spoken }
        if let spoken = FrontEndTables.functionWords[lower], !(w.count > 1 && Self.isUppercase(w)) { return spoken }
        if SpeechNormalizer.alwaysSpell.contains(w) || (w.count >= 2 && !Self.vowelLetters.isMatch(w)) {
            return Self.spelled(w.map(String.init))    // 'km', 'tbh', 'PBS': no vowel letter, spell it
        }
        if w.count == 1, Self.isUppercase(w), w != "I", w != "A" {
            return FrontEndTables.letterNames[lower] ?? ""
        }
        if (Self.acronym.fullMatches(w) && lookup(w) == nil) || (Self.shortAcronym.fullMatches(w) && lexicon.pronunciation(of: w) == nil) {
            let stem = String(w.reversed().drop { $0 == "s" }.reversed())
            let plural = w.hasSuffix("s") && w.count > 2
            var names = stem.compactMap { FrontEndTables.letterNames[String($0).lowercased()] }
            if plural { names.append("z") }
            return names.enumerated().map { index, name in
                index < names.count - 1 ? name.replacingLiteral("ˈ", with: "ˌ") : name
            }.joined()
        }
        if let found = lookup(w) { return found }
        if lower.hasSuffix("'s"), let stem = lookup(String(lower.dropLast(2))) { return stem + "z" }
        // two dictionary words glued together ('hydroxyvitamin')
        let characters = Array(lower)
        if characters.count >= 6 {
            for split in stride(from: characters.count - 3, through: 3, by: -1) {
                let head = String(characters[..<split]), tail = String(characters[split...])
                if let a = lookup(head), let b = lookup(tail), head.count >= 3, tail.count >= 4 {
                    return a.replacingLiteral("ˈ", with: "ˌ") + b
                }
            }
        }
        let letters = Self.nonLetters.sub(lower, template: "")
        return Espeakify.espeakify(Espeakify.ipa(fromArpabet: neural.phones(for: letters)), word: lower)
    }

    // MARK: Text

    private static let tensJoin = Rx("\\b(\(FrontEndTables.tensWords.joined(separator: "|")))-(one|two|three|four|five|six|seven|eight|nine)\\b")
    private static let tokenizer = Rx("[A-Za-z]+@?(?:['’][A-Za-z]+)?|[.,!?;:—…\"“”]")
    private static let joinedTens = Rx("^(\(FrontEndTables.tensWords.joined(separator: "|")))(.+)@")

    /// How the shared tokenizer reads text for one voice. Kitten's is the default; Kokoro (#2705) reads numbers
    /// the way misaki does, keeps the dash and the ellipsis, uses curly quotes, and says 'eighty four' as two words.
    struct TextStyle {
        var numbers: SpeechNormalizer.NumberReading = .kitten
        var joinTens = true
        var keepDashes = false
        var openQuote = "\""
        var closeQuote = "\""
    }

    /// Text to a phoneme string in phonemizer's shape: words space-separated, punctuation kept.
    public func phonemize(_ text: String) -> String {
        var (out, _) = phonemizeWords(text, style: TextStyle(), word: { self.word($0) })
        // 'the' before a vowel sound
        if out.count > 1 {
            for index in 0..<(out.count - 1) where out[index] == "ðə" || out[index] == "\"ðə" {
                if Self.vowelStart.isMatch(out[index + 1]) { out[index] = String(out[index].dropLast()) + "ɪ" }
            }
        }
        return out.joined(separator: " ")
    }

    /// The tokenizer both voices share: normalize, then each word through `word`, punctuation attached to the word
    /// before it. Returns the phonemes per word and, in step, the word each came from ("" for a joined pair).
    func phonemizeWords(_ text: String, style: TextStyle, word wordPhonemes: (String) -> String) -> (phonemes: [String], sources: [String]) {
        var t = SpeechNormalizer.normalize(text, numbers: style.numbers)
        var out: [String] = []
        var sources: [String] = []
        var pending = ""
        var openQuote = false
        if style.joinTens { t = Self.tensJoin.sub(t, template: "$1$2@") }
        for match in Self.tokenizer.matches(in: t) {
            let token = match.whole
            if token.hasSuffix("@") {                              // 'eighty-four' said as one word
                if let joined = Self.joinedTens.firstMatch(in: token) {
                    out.append(pending + wordPhonemes(joined.group(1) ?? "") + wordPhonemes(joined.group(2) ?? ""))
                    sources.append("")
                }
                pending = ""
                continue
            }
            if let first = token.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic {
                let source = token.replacingLiteral("’", with: "'")
                out.append(pending + wordPhonemes(source))
                sources.append(source)
                pending = ""
            } else if token == "\"" || token == "“" || token == "”" {
                if openQuote || token == "”" {
                    if !out.isEmpty { out[out.count - 1] += style.closeQuote }
                    openQuote = false
                } else {
                    pending = style.openQuote
                    openQuote = true
                }
            } else {
                let mark = style.keepDashes ? token : token == "—" ? "," : token == "…" ? "." : token
                if !out.isEmpty { out[out.count - 1] += mark }
            }
        }
        return (out, sources)
    }

    // MARK: Ids

    private static let symbolIDs: [UInt32: Int64] = Dictionary(
        FrontEndTables.kittenSymbols.map { ($0.0, Int64($0.1)) }, uniquingKeysWith: { _, later in later }
    )

    /// Python's `\w`: letters, numbers and the underscore.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Phonemes to ids: Python's `re.findall(r"\w+|[^\w\s]")` tokens joined by spaces, then one id per
    /// code point Kitten knows. The ids start with pad and end with an ellipsis and pad.
    static func inputIDs(forPhonemes phonemes: String) -> [Int64] {
        var tokens: [String.UnicodeScalarView] = []
        var run = String.UnicodeScalarView()
        for scalar in phonemes.unicodeScalars {
            if isWordScalar(scalar) {
                run.append(scalar)
                continue
            }
            if !run.isEmpty { tokens.append(run); run = String.UnicodeScalarView() }
            if !scalar.properties.isWhitespace { tokens.append(String.UnicodeScalarView([scalar])) }
        }
        if !run.isEmpty { tokens.append(run) }
        var ids: [Int64] = [0]
        for (index, token) in tokens.enumerated() {
            if index > 0, let space = symbolIDs[0x20] { ids.append(space) }
            for scalar in token { if let id = symbolIDs[scalar.value] { ids.append(id) } }
        }
        return ids + [10, 0]
    }
}
