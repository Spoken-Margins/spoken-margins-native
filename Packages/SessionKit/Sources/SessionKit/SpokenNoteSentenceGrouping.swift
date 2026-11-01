import Foundation

/// Groups the transcriber's timed words (or short phrases) into the sentences a spoken note shows and plays (#3108).
///
/// A pure function of the transcriber's output, so it is tested on the host. Dictated text is never removed: every
/// non-empty word ends up in exactly one sentence, in the order spoken, and the sentences' text joined by a space is
/// the words joined by a space. Only where a sentence breaks is decided here.
///
/// A sentence ends after a word that ends in `.`, `!`, `?` or `…` (closing quotes and brackets may follow), unless
/// that word is an initial or a common abbreviation ("Dr.", "e.g."). Dictation often arrives without punctuation, so
/// a pause also ends a sentence, and so does a run of `maxWordsPerSentence` words, so that one long ramble stays
/// tappable in pieces.
public enum SpokenNoteSentenceGrouping {
    /// A silence this long between two words starts a new sentence.
    public static let pauseBreakMs = 1_500
    /// A sentence never holds more than this many words.
    public static let maxWordsPerSentence = 40

    private static let closers = CharacterSet(charactersIn: "\"'’”)]}»")
    private static let terminators = CharacterSet(charactersIn: ".!?…")
    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "vs.", "etc.", "e.g.", "i.e.", "no.", "approx.", "fig.",
        "inc.", "ltd.", "co.", "u.s.", "u.k.",
    ]

    public static func sentences(from words: [AlignedTranscriptSegment]) -> [SpokenNoteSentence] {
        // Words in spoken order. The sort is stable, so words with the same start keep the order they came in.
        let spoken = words.enumerated()
            .map { (index: $0.offset, word: $0.element, text: $0.element.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .sorted { ($0.word.startMs, $0.index) < ($1.word.startMs, $1.index) }

        var sentences: [SpokenNoteSentence] = []
        var texts: [String] = []
        var start = 0
        var end = 0
        var wordCount = 0

        func flush() {
            guard !texts.isEmpty else { return }
            sentences.append(SpokenNoteSentence(text: texts.joined(separator: " "), startMs: start, endMs: end))
            texts = []
            wordCount = 0
        }

        for item in spoken {
            let wordStart = max(0, item.word.startMs)
            let wordEnd = max(wordStart, item.word.endMs)
            if !texts.isEmpty, wordStart - end >= pauseBreakMs { flush() }
            if texts.isEmpty { start = wordStart; end = wordEnd } else { end = max(end, wordEnd) }
            texts.append(item.text)
            wordCount += item.text.split(whereSeparator: \.isWhitespace).count
            if endsSentence(item.text) || wordCount >= maxWordsPerSentence { flush() }
        }
        flush()
        return sentences
    }

    /// Whether `word` closes a sentence by its punctuation.
    static func endsSentence(_ word: String) -> Bool {
        var scalars = Substring(word).unicodeScalars
        while let last = scalars.last, closers.contains(last) { scalars.removeLast() }
        guard let last = scalars.last, terminators.contains(last) else { return false }
        guard last == "." else { return true }
        let core = String(String.UnicodeScalarView(scalars)).lowercased()
        if abbreviations.contains(core) { return false }
        // A single capital letter and a dot is an initial ("J. Smith"), not the end of a sentence.
        let letters = core.dropLast()
        if letters.count == 1, let only = letters.first, only.isLetter, word.first?.isUppercase == true { return false }
        return true
    }
}
