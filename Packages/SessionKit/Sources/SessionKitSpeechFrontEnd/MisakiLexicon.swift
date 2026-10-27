import Foundation

/// misaki's American English dictionaries, gold then silver, read in misaki's own phoneme spelling (#2705).
///
/// Kokoro was trained on text that misaki's English G2P (`misaki/en.py`, Apache-2.0, hexgrad) had phonemized, so
/// this is the lookup half of that G2P without the part that needs MLX (its BART fallback and its POS tagger).
/// The gold dictionary has about 90,000 entries and the silver one about 93,000 more; `us_gold.json` and
/// `us_silver.json` are downloaded with the voice from a pinned commit of github.com/hexgrad/misaki, and
/// `KokoroModelPreparer` turns them once into the sorted `word<TAB>phonemes` file this reads in place.
///
/// What is ported from `Lexicon`: the gold-then-silver lookup, the all-caps and Capitalised fallbacks to the
/// lower-case entry, the `'s`/`s`, `ed` and `ing` stemmers and the possessive rules. What is not: part-of-speech
/// variants (a heteronym reads as its `DEFAULT`), and `get_NNP`'s spelling of unknown capitalised words, which the
/// caller's fallback handles.
public final class MisakiLexicon: Sendable {
    private let table: PronunciationLexicon

    public init(contentsOf url: URL) throws {
        table = try PronunciationLexicon(contentsOf: url)
    }

    // MARK: Building the file

    public enum BuildError: Error, Equatable {
        case notADictionary
        case noEntries
    }

    /// The merged file: every gold entry (a heteronym as its `DEFAULT`), then each silver entry gold doesn't have,
    /// one `word<TAB>phonemes` line each, sorted by UTF-8 bytes so `PronunciationLexicon` can search it in place.
    public static func tsv(goldJSON: Data, silverJSON: Data) throws -> Data {
        var merged: [String: String] = [:]
        for source in [silverJSON, goldJSON] {            // gold last, so it wins
            guard let object = try JSONSerialization.jsonObject(with: source) as? [String: Any] else { throw BuildError.notADictionary }
            for (word, value) in object {
                let phonemes: String?
                if let text = value as? String {
                    phonemes = text
                } else if let variants = value as? [String: Any] {
                    phonemes = variants["DEFAULT"] as? String
                } else {
                    phonemes = nil
                }
                guard let phonemes, !phonemes.isEmpty, !word.isEmpty,
                      !word.contains("\t"), !word.contains("\n"), !phonemes.contains("\t"), !phonemes.contains("\n")
                else { continue }
                merged[word] = phonemes
            }
        }
        guard !merged.isEmpty else { throw BuildError.noEntries }
        let lines = merged.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
        return Data(lines.map { "\($0.key)\t\($0.value)\n" }.joined().utf8)
    }

    // MARK: Lookup

    /// The entry stored for exactly this word.
    public func entry(_ word: String) -> String? { table.pronunciation(of: word) }

    private static let primary: Character = "ˈ", secondary: Character = "ˌ"
    private static let vowels = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    private static let usTaus = Set("AIOWYiuæɑəɛɪɹʊʌ")

    /// Misaki's `is_known`, for a word that isn't an entry: a short letter, an all-caps spelling of an entry.
    private func isKnown(_ word: String) -> Bool {
        entry(word) != nil
    }

    private func s(_ stem: String) -> String? {
        guard let last = stem.last else { return nil }
        if "ptkfθ".contains(last) { return stem + "s" }
        if "szʃʒʧʤ".contains(last) { return stem + "ᵻz" }
        return stem + "z"
    }

    private func ed(_ stem: String) -> String? {
        guard let last = stem.last else { return nil }
        if "pkfθʃsʧ".contains(last) { return stem + "t" }
        if last == "d" { return stem + "ᵻd" }
        if last != "t" { return stem + "d" }
        let characters = Array(stem)
        if characters.count < 2 { return stem + "ɪd" }
        if Self.usTaus.contains(characters[characters.count - 2]) { return String(stem.dropLast()) + "ɾᵻd" }
        return stem + "ᵻd"
    }

    private func ing(_ stem: String) -> String? {
        let characters = Array(stem)
        guard let last = characters.last else { return nil }
        if characters.count > 1, last == "t", Self.usTaus.contains(characters[characters.count - 2]) {
            return String(stem.dropLast()) + "ɾɪŋ"
        }
        return stem + "ɪŋ"
    }

    /// `stem_s`: plurals, third person and possessives made from an entry.
    private func stemS(_ word: String) -> String? {
        guard word.count >= 3, word.hasSuffix("s") else { return nil }
        let stem: String
        if !word.hasSuffix("ss"), isKnown(String(word.dropLast())) {
            stem = String(word.dropLast())
        } else if (word.hasSuffix("'s") || (word.count > 4 && word.hasSuffix("es") && !word.hasSuffix("ies"))),
                  isKnown(String(word.dropLast(2))) {
            stem = String(word.dropLast(2))
        } else if word.count > 4, word.hasSuffix("ies"), isKnown(String(word.dropLast(3)) + "y") {
            stem = String(word.dropLast(3)) + "y"
        } else {
            return nil
        }
        return entry(stem).flatMap(s)
    }

    private func stemEd(_ word: String) -> String? {
        guard word.count >= 4, word.hasSuffix("d") else { return nil }
        let stem: String
        if !word.hasSuffix("dd"), isKnown(String(word.dropLast())) {
            stem = String(word.dropLast())
        } else if word.count > 4, word.hasSuffix("ed"), !word.hasSuffix("eed"), isKnown(String(word.dropLast(2))) {
            stem = String(word.dropLast(2))
        } else {
            return nil
        }
        return entry(stem).flatMap(ed)
    }

    private static let doubledConsonantIng = Rx("([bcdgklmnprstvxz])\\1ing$|cking$")

    private func stemIng(_ word: String) -> String? {
        guard word.count >= 5, word.hasSuffix("ing") else { return nil }
        let stem: String
        if word.count > 5, isKnown(String(word.dropLast(3))) {
            stem = String(word.dropLast(3))
        } else if isKnown(String(word.dropLast(3)) + "e") {
            stem = String(word.dropLast(3)) + "e"
        } else if word.count > 5, Self.doubledConsonantIng.isMatch(word), isKnown(String(word.dropLast(4))) {
            stem = String(word.dropLast(4))
        } else {
            return nil
        }
        return entry(stem).flatMap(ing)
    }

    /// Misaki's `get_word` without tags: the entry for the word, or one made from a stem. Nil when the
    /// dictionaries have neither, so the caller spells it another way.
    public func pronunciation(of word: String) -> String? {
        guard !word.isEmpty else { return nil }
        let lower = word.lowercased()
        var key = word
        if word.count > 1, word != lower, entry(word) == nil,
           word == word.uppercased() || word.dropFirst() == word.dropFirst().lowercased(),
           entry(lower) != nil || stemS(lower) != nil || stemEd(lower) != nil || stemIng(lower) != nil {
            key = lower
        }
        if let found = entry(key) { return found }
        if key.hasSuffix("s'"), let found = entry(String(key.dropLast(2)) + "'s") { return found }
        if key.hasSuffix("'"), let found = entry(String(key.dropLast())) { return found }
        if let found = stemS(key) ?? stemEd(key) { return found }
        return stemIng(key)
    }
}
