import Foundation

/// Text to Kokoro-82M input ids (#2705) with no GPL code and no MLX.
///
/// Kokoro was trained on text that misaki's English G2P had phonemized. This front end follows misaki as closely
/// as it can without MLX (whose BART fallback and POS tagger are what need the Metal toolchain and the GPU, which
/// iOS refuses in the background, so the voice stays on the Neural Engine and CPU):
///
/// 1. Numbers, years, money and times are read the way misaki reads them: plain words, no commas
///    (`SpeechNormalizer.NumberReading.misaki`). Kitten's comma and hand-spelled 'hundred' are Kitten's own fixes.
/// 2. A word is looked up in misaki's gold dictionary, then its silver one (`MisakiLexicon`), in misaki's own
///    spelling, with misaki's stemming for plurals, `ed` and `ing`.
/// 3. Only a word in neither goes to the Kitten front end (CMUdict, a split into two words, the small
///    letter-to-sound net), respelled from espeak's conventions into misaki's with misaki's own espeak fallback
///    table (`misaki/espeak.py`, `EspeakFallback.E2M`, Apache-2.0) for American English.
/// 4. 'the' and 'to' take their vowel-sensitive forms from the next word, as in `Lexicon.get_special_case`.
///
/// What stays different from misaki: no part-of-speech, so a heteronym ('read', 'lead') reads as its default.
public struct KokoroFrontEnd: Sendable {
    /// Kokoro's padding and boundary token.
    public static let boundaryTokenID: Int32 = 0

    private let vocab: [Character: Int32]
    private let phonemizer: @Sendable (String) -> String
    /// Whether `phonemizer` speaks espeak (and needs respelling) or already speaks misaki.
    private let respells: Bool

    /// `vocabJSON` is the port's `runtime/kokoro-vocab.json` (`{"vocab": {"a": 43, …}}`). `phonemizer` gives
    /// espeak-spelled phonemes for text; the app passes `KittenFrontEnd.phonemize`.
    public init(vocabJSON: Data, phonemizer: @escaping @Sendable (String) -> String) throws {
        vocab = try Self.vocabulary(vocabJSON)
        self.phonemizer = phonemizer
        respells = true
    }

    /// The reading the app uses: misaki's dictionaries first, `kitten` only for a word they don't have.
    public init(vocabJSON: Data, lexicon: MisakiLexicon, fallback kitten: KittenFrontEnd) throws {
        vocab = try Self.vocabulary(vocabJSON)
        phonemizer = { Self.misakiPhonemes(for: $0, lexicon: lexicon, fallback: kitten) }
        respells = false
    }

    private static func vocabulary(_ vocabJSON: Data) throws -> [Character: Int32] {
        struct File: Decodable { let vocab: [String: Int32] }
        let decoded = try JSONDecoder().decode(File.self, from: vocabJSON)
        var table: [Character: Int32] = [:]
        for (key, value) in decoded.vocab where key.count == 1 {
            table[Character(key)] = value
        }
        guard !table.isEmpty else { throw KokoroFrontEndError.emptyVocabulary }
        return table
    }

    public struct Input: Equatable, Sendable {
        /// Boundary, the phoneme tokens, boundary, then boundary padding to `paddedLength`.
        public var inputIds: [Int32]
        /// 1 over the framed tokens, 0 over the padding.
        public var attentionMask: [Int32]
        /// Framed length (tokens plus the two boundaries).
        public var tokenCount: Int
        /// Which row of the voice's style table to use: the phoneme string's UTF-16 length less one, as the port does.
        public var styleRow: Int
        /// Phoneme characters the vocabulary doesn't have, dropped.
        public var droppedCharacters: Int
    }

    /// Misaki-spelled phonemes for `text`.
    public func phonemes(for text: String) -> String {
        respells ? Self.misaki(fromEspeak: phonemizer(text)) : phonemizer(text)
    }

    // MARK: Misaki reading

    private static let kokoroStyle = KittenFrontEnd.TextStyle(
        numbers: .misaki, joinTens: false, keepDashes: true, openQuote: "“", closeQuote: "”")
    private static let vowelPhonemes = Set("AIOQWYaiuæɑɒɔəɐɛɜɪʊʌᵻ")
    private static let consonantPhonemes = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
    private static let framing = Set("“\"")
    private static let trailingMarks = Set(";:,.!?—…”\")(")

    /// `Lexicon.get_special_case` for the words it settles by their neighbours or by being function words, and the
    /// dictionaries for the rest, with the Kitten front end for a word in neither.
    static func misakiWord(_ word: String, lexicon: MisakiLexicon, fallback kitten: KittenFrontEnd) -> String {
        switch word {
        case "a", "A": return "ɐ"
        case "an", "An": return "ɐn"
        case "I": return "ˌI"
        case "in", "In": return "ɪn"
        case "the", "The": return "ði"          // 'ðə' before a consonant, settled once the next word is known
        case "to", "To": return "tu"            // 'tə' or 'tʊ' likewise
        default: break
        }
        let spelledOut = SpeechNormalizer.alwaysSpell.contains(word)
            || (word.count >= 2 && !KittenFrontEnd.vowelLetters.isMatch(word))
            || (word.count == 1 && KittenFrontEnd.isUppercase(word))
        if spelledOut { return misaki(fromEspeak: kitten.word(word)) }
        let known = lexicon.pronunciation(of: word)
        let acronym = (KittenFrontEnd.acronym.fullMatches(word) || KittenFrontEnd.shortAcronym.fullMatches(word))
        if known == nil, acronym { return misaki(fromEspeak: kitten.word(word)) }
        if let known { return known }
        return misaki(fromEspeak: kitten.word(word))
    }

    /// Whether the word after `index` starts with a vowel sound (true), a consonant (false), or can't be told (nil).
    private static func vowelFollows(_ pieces: [String], after index: Int) -> Bool? {
        guard index + 1 < pieces.count else { return nil }
        for character in pieces[index + 1] {
            if vowelPhonemes.contains(character) { return true }
            if consonantPhonemes.contains(character) { return false }
            if !framing.contains(character), character != "ˈ", character != "ˌ" { return nil }
        }
        return nil
    }

    /// Misaki-spelled phonemes for the text.
    static func misakiPhonemes(for text: String, lexicon: MisakiLexicon, fallback kitten: KittenFrontEnd) -> String {
        var (pieces, sources) = kitten.phonemizeWords(text, style: kokoroStyle) {
            misakiWord($0, lexicon: lexicon, fallback: kitten)
        }
        for index in pieces.indices where ["the", "The", "to", "To"].contains(sources[index]) {
            let piece = pieces[index]
            let lead = String(piece.prefix { framing.contains($0) })
            let trail = String(piece.reversed().prefix { trailingMarks.contains($0) }.reversed())
            let core = String(piece.dropFirst(lead.count).dropLast(trail.count))
            let vowel = trail.isEmpty ? vowelFollows(pieces, after: index) : nil
            let isThe = sources[index].lowercased() == "the"
            let spoken: String
            switch (isThe, vowel) {
            case (true, true?): spoken = core                      // ði
            case (true, _): spoken = "ðə"
            case (false, true?): spoken = "tʊ"
            case (false, false?): spoken = "tə"
            default: spoken = core                                 // 'to' at the end of a phrase keeps its full form
            }
            pieces[index] = lead + spoken + trail
        }
        return pieces.joined(separator: " ")
    }

    /// Model input for `text`, or nil when it holds no sound or more than `paddedLength` tokens framed.
    public func input(for text: String, paddedLength: Int = 128) -> Input? {
        let phonemes = phonemes(for: text)
        var ids: [Int32] = []
        var dropped = 0
        for character in phonemes {
            if let id = vocab[character] { ids.append(id) } else { dropped += 1 }
        }
        let silence = vocab[" "]
        guard ids.contains(where: { $0 != silence }) else { return nil }
        let framed = [Self.boundaryTokenID] + ids + [Self.boundaryTokenID]
        guard framed.count <= paddedLength else { return nil }
        let padding = paddedLength - framed.count
        return Input(
            inputIds: framed + [Int32](repeating: Self.boundaryTokenID, count: padding),
            attentionMask: [Int32](repeating: 1, count: framed.count) + [Int32](repeating: 0, count: padding),
            tokenCount: framed.count,
            styleRow: max(0, phonemes.utf16.count - 1),
            droppedCharacters: dropped
        )
    }

    /// Longest first, as misaki sorts them. Kitten's espeak spelling has no tie bars, so the pairs are adjacent.
    /// misaki's tied `ə^l` → `ᵊl` (a syllabic l) is left out: untied, it would also catch "hello"'s `əl`.
    static let espeakToMisaki: [(String, String)] = [
        ("ʔˌn\u{0329}", "ʔn"), ("ʔn\u{0329}", "ʔn"),
        ("aɪ", "I"), ("aʊ", "W"), ("dʒ", "ʤ"), ("eɪ", "A"), ("tʃ", "ʧ"), ("ɔɪ", "Y"), ("oʊ", "O"),
        ("ʲo", "jo"), ("ʲə", "jə"),
        ("ʲ", ""), ("ɚ", "əɹ"), ("r", "ɹ"), ("x", "k"), ("ç", "k"), ("ɐ", "ə"), ("ɬ", "l"), ("\u{0303}", ""), ("e", "A")
    ]

    /// misaki's American respelling of espeak phonemes.
    public static func misaki(fromEspeak espeak: String) -> String {
        var s = espeak
        for (old, new) in espeakToMisaki { s = s.replacingOccurrences(of: old, with: new) }
        s = s.replacingOccurrences(of: "ɜːɹ", with: "ɜɹ")
            .replacingOccurrences(of: "ɜː", with: "ɜɹ")
            .replacingOccurrences(of: "ɪə", with: "iə")
            .replacingOccurrences(of: "ː", with: "")
            .replacingOccurrences(of: "o", with: "ɔ")
            .replacingOccurrences(of: "ɾ", with: "T")
            .replacingOccurrences(of: "ʔ", with: "t")
        return s
    }
}

public enum KokoroFrontEndError: Error, Equatable {
    case emptyVocabulary
}
