import Foundation

/// A word the live recogniser heard, with its time in the recogniser's own audio clock (zero is the first buffer it
/// was fed). Plain values, so the phrase rule below is pure and the host can test it.
public struct MarginEndPhraseWord: Sendable, Equatable {
    public var text: String
    public var startMs: Int
    public var endMs: Int

    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// The spoken end of a Margin (#3940, #3650, PR 1 of the Design): which words, said how, end it.
///
/// The listener ends a Margin by saying "stop margin" or "end margin" and then nothing for a second. Nothing else ends
/// a hands-free Margin: not silence, not a press. There is no quiet timer in this file and there must never be one; a
/// pause of any length with no phrase gives `.none` (`MarginEndPhraseTests`, `NoQuietEndTests`).
///
/// The rule, in order:
/// 1. **Words.** Case, Unicode form (NFC), punctuation and quotes don't matter: "Stop, margin.", "STOP MARGIN" and
///    "\u{201C}stop margin\u{201D}" are the same words. Only whole words count.
/// 2. **Phrases.** "stop margin" and "end margin", and "stop the margin" and "end the margin" (people add "the").
///    The on-device recogniser also writes "margin" as "martian" and "end" as "and" (the owner's phone, 2026-11-17),
///    so "stop martian", "end martian" and "and martian" count too. "and martian" is plain English, so it also needs
///    a pause of 0.4 s before it. "and margin" and "stop the martian" are not phrases.
/// 3. **Close together.** Each word of the phrase starts within 0.8 s of the end of the one before it.
/// 4. **Last words.** The phrase must be the last thing heard, and the recogniser's audio clock must have moved 1.0 s
///    past its end with no further word. That second confirms a spoken command; it is not a silence rule. A word in
///    that second ("stop margin notes") cancels it.
/// 5. **Not too early.** A phrase that starts in the first second of capture is ignored: nothing has been said yet.
public enum MarginEndPhrase {
    /// What the rule says now. `phraseStartMs` and `cutAtMs` are in the recogniser's clock; the cut of the saved
    /// audio is taken from the saved file's own transcript (`trailingPhrase(in:)` on its words), not from these.
    public enum Outcome: Sendable, Equatable {
        case none
        /// The phrase was heard as the last words; waiting out the confirming second.
        case confirming(phraseStartMs: Int)
        /// Confirmed: end and save. `cutAtMs` is 150 ms before the phrase's first word.
        case end(cutAtMs: Int)
    }

    /// Where the phrase sits in the words it was found in.
    public struct Match: Sendable, Equatable {
        public var firstWordIndex: Int
        public var startMs: Int
        public var endMs: Int
        /// Where to cut the audio so the phrase is gone: a little before its first word.
        public var cutAtMs: Int { max(0, startMs - MarginEndPhrase.cutLeadMs) }
    }

    /// A phrase that starts earlier than this after capture began is ignored.
    public static let earliestStartMs = 1_000
    /// The most one word of the phrase may start after the end of the one before.
    public static let maxWordGapMs = 800
    /// How far the audio clock must move past the phrase's end, with nothing more heard, to confirm it.
    public static let confirmMs = 1_000
    /// The pause "and martian" needs before it, because "and" starts so many ordinary sentences.
    public static let andLeadPauseMs = 400
    /// The audio kept before the phrase when it is cut.
    public static let cutLeadMs = 150

    /// The rule on the words heard so far (oldest first) and the recogniser's audio clock.
    public static func evaluate(words: [MarginEndPhraseWord], audioNowMs: Int) -> Outcome {
        guard let match = trailingPhrase(in: words), match.startMs >= earliestStartMs else { return .none }
        if audioNowMs - match.endMs >= confirmMs { return .end(cutAtMs: match.cutAtMs) }
        return .confirming(phraseStartMs: match.startMs)
    }

    /// The phrase at the very end of `words`, if there is one: rules 1 to 3 and "last words", with no confirming
    /// second and no early-start rule. This is what cuts a saved Margin, whose file ends a second after the phrase,
    /// and what the live rule is built on. A phrase said again straight away (within the confirming second of the
    /// one before) counts as one, so the cut takes both.
    public static func trailingPhrase(in words: [MarginEndPhraseWord]) -> Match? {
        let tokens = tokenize(words)
        guard let last = tokens.last, var start = phraseStart(endingAt: tokens.count - 1, in: tokens) else { return nil }
        while start > 0, let earlier = phraseStart(endingAt: start - 1, in: tokens),
              tokens[start].startMs - tokens[start - 1].endMs <= confirmMs {
            start = earlier
        }
        return Match(firstWordIndex: tokens[start].wordIndex, startMs: tokens[start].startMs, endMs: last.endMs)
    }

    // MARK: Words

    struct Token: Equatable {
        var text: String
        var wordIndex: Int
        var startMs: Int
        var endMs: Int
    }

    /// Lowercase NFC tokens of letters, digits and apostrophes (a curly one counts as a straight one). A word the
    /// recogniser wrote as several tokens ("stop-margin") shares its time between them by length.
    static func tokenize(_ words: [MarginEndPhraseWord]) -> [Token] {
        var tokens: [Token] = []
        for (index, word) in words.enumerated() {
            let normalised = word.text.precomposedStringWithCanonicalMapping.lowercased()
                .replacingOccurrences(of: "\u{2019}", with: "'")
            let pieces = normalised
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
                .filter { !$0.isEmpty }
            guard !pieces.isEmpty else { continue }
            let total = max(1, pieces.reduce(0) { $0 + $1.count })
            let span = max(0, word.endMs - word.startMs)
            var offset = 0
            for piece in pieces {
                let from = word.startMs + span * offset / total
                offset += piece.count
                let to = word.startMs + span * offset / total
                tokens.append(Token(text: piece, wordIndex: index, startMs: from, endMs: to))
            }
        }
        return tokens
    }

    // MARK: Phrases

    /// The index of the first token of a phrase that ends at `end`, if one does.
    private static func phraseStart(endingAt end: Int, in tokens: [Token]) -> Int? {
        guard end >= 1 else { return nil }
        let closer = tokens[end].text
        guard closer == "margin" || closer == "martian" else { return nil }
        var start = end - 1
        if closer == "margin", tokens[start].text == "the", start >= 1 { start -= 1 }
        let opener = tokens[start].text
        switch opener {
        case "stop", "end":
            break
        case "and":
            guard closer == "martian" else { return nil }
            if start > 0, tokens[start].startMs - tokens[start - 1].endMs < andLeadPauseMs { return nil }
        default:
            return nil
        }
        for index in start..<end where tokens[index + 1].startMs - tokens[index].endMs > maxWordGapMs { return nil }
        return start
    }
}

/// The recogniser's results as they arrive, kept short, with the phrase rule run on them (#3940). Each batch is one
/// result's words. A later result replaces every word that starts at or after its first word (a volatile guess that
/// was revised, or one a final result now covers), so the window holds the recogniser's current reading of the last
/// few seconds and nothing older: memory stays flat for a Margin of any length.
public struct MarginEndPhraseWindow: Sendable {
    /// How much of the audio's recent past is kept. The rule needs only the phrase and the word before it.
    public static let retainMs = 10_000

    public private(set) var words: [MarginEndPhraseWord] = []

    public init() {}

    /// Takes the next result (empty for none) and the recogniser's audio clock, which is how far it has processed
    /// the audio, not the wall clock. Gives what the rule says now.
    public mutating func advance(audioNowMs: Int, hearing batch: [MarginEndPhraseWord] = []) -> MarginEndPhrase.Outcome {
        if let first = batch.first {
            words.removeAll { $0.startMs >= first.startMs }
            words.append(contentsOf: batch)
        }
        let cutoff = audioNowMs - Self.retainMs
        words.removeAll { $0.endMs < cutoff }
        return MarginEndPhrase.evaluate(words: words, audioNowMs: audioNowMs)
    }
}
