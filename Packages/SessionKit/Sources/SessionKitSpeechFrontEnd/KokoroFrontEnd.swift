import Foundation

/// Text to Kokoro-82M input ids (#2705) with no GPL code and no MLX: the bundled Kitten front end's
/// pronunciations (misaki gold lexicon, CMUdict, the small letter-to-sound net), respelled from espeak's
/// conventions into misaki's, which is the phoneme set Kokoro was trained on. The respelling is misaki's own
/// espeak fallback table (`misaki/espeak.py`, `EspeakFallback.E2M`, Apache-2.0) for American English.
///
/// The port's own front end (MisakiSwift) runs a BART fallback on MLX, which needs the Metal toolchain to build
/// and the GPU to run, and iOS refuses GPU work in the background; this keeps the voice on the Neural Engine
/// and CPU only.
public struct KokoroFrontEnd: Sendable {
    /// Kokoro's padding and boundary token.
    public static let boundaryTokenID: Int32 = 0

    private let vocab: [Character: Int32]
    private let phonemizer: @Sendable (String) -> String

    /// `vocabJSON` is the port's `runtime/kokoro-vocab.json` (`{"vocab": {"a": 43, …}}`). `phonemizer` gives
    /// espeak-spelled phonemes for text; the app passes `KittenFrontEnd.phonemize`.
    public init(vocabJSON: Data, phonemizer: @escaping @Sendable (String) -> String) throws {
        struct File: Decodable { let vocab: [String: Int32] }
        let decoded = try JSONDecoder().decode(File.self, from: vocabJSON)
        var table: [Character: Int32] = [:]
        for (key, value) in decoded.vocab where key.count == 1 {
            table[Character(key)] = value
        }
        guard !table.isEmpty else { throw KokoroFrontEndError.emptyVocabulary }
        vocab = table
        self.phonemizer = phonemizer
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
        Self.misaki(fromEspeak: phonemizer(text))
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
