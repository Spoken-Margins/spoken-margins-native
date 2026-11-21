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
        /// Where the last phrase of the run starts. It is `startMs` unless the phrase was said again straight away.
        public var finalPhraseStartMs: Int
        /// The index, among the words' tokens, of the phrase's first token.
        var firstTokenIndex: Int
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

    /// The rule on the words heard so far (oldest first) and `audioNowMs`, the time through which the recogniser has
    /// **delivered results**. Not the microphone's clock: results lag the audio, and a word spoken in the confirming
    /// second may not be delivered yet, so a clock ahead of the results could end a Margin on "stop margin notes".
    public static func evaluate(words: [MarginEndPhraseWord], audioNowMs: Int) -> Outcome {
        // The early-start rule looks at the last phrase said, not at an earlier try the cut also takes.
        guard let match = trailingPhrase(in: words), match.finalPhraseStartMs >= earliestStartMs else { return .none }
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
        let finalStartMs = tokens[start].startMs
        while start > 0, let earlier = phraseStart(endingAt: start - 1, in: tokens),
              tokens[start].startMs - tokens[start - 1].endMs <= confirmMs {
            start = earlier
        }
        return Match(firstWordIndex: tokens[start].wordIndex, startMs: tokens[start].startMs, endMs: last.endMs,
                     finalPhraseStartMs: finalStartMs, firstTokenIndex: start)
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

/// A saved Margin's transcript with the trailing end phrase taken off (#3940, the cut, PR 2).
public struct MarginEndPhraseCut: Sendable, Equatable {
    /// Where to cut the audio: 150 ms before the phrase's first word, in the saved file's time.
    public var cutAtMs: Int
    /// The transcript text without the phrase, with the punctuation before it kept.
    public var text: String
    /// How many leading words (segments) are kept. The rest are the phrase.
    public var keptWordCount: Int
}

extension MarginEndPhrase {
    /// The cut for a saved Margin whose final words are `words` (one per transcript segment) and whose full text is
    /// `text`: where to cut, the text without the phrase, and how many words stay. `nil` means keep everything: no
    /// phrase at the end, a phrase that shares a word with the speech before it, text that doesn't end with the
    /// words the phrase was found in (the recogniser's two readings disagree, and losing the listener's words is
    /// worse than keeping "stop margin"), or nothing left once the phrase is gone.
    public static func cut(text: String, words: [MarginEndPhraseWord]) -> MarginEndPhraseCut? {
        guard let match = trailingPhrase(in: words), match.firstWordIndex > 0 else { return nil }
        let tokens = tokenize(words)
        let first = match.firstTokenIndex
        // The phrase must start its own recognised word: one word holding "okay stop" can't be split, and a phrase
        // with no token before it leaves nothing to keep.
        guard first > 0, tokens[first - 1].wordIndex != tokens[first].wordIndex else { return nil }
        // Cut before the phrase, but never into the last kept word: recogniser times often touch, and 150 ms back
        // from a phrase that starts the moment the word ends would clip it. Overlapping words keep everything.
        let lastKeptEndMs = tokens[first - 1].endMs
        guard lastKeptEndMs <= match.startMs else { return nil }
        let cutAtMs = max(match.cutAtMs, lastKeptEndMs)
        guard cutAtMs > 0 else { return nil }
        let droppedTokens = tokens[first...].map(\.text)
        guard let trimmed = textDroppingTrailingTokens(text, expecting: droppedTokens) else { return nil }
        return MarginEndPhraseCut(cutAtMs: cutAtMs, text: trimmed, keptWordCount: match.firstWordIndex)
    }

    /// `text` without its last `expecting.count` word tokens, only when those are exactly `expecting`; the text
    /// before them keeps its own punctuation and loses trailing space. `nil` when they differ or nothing is left.
    static func textDroppingTrailingTokens(_ text: String, expecting: [String]) -> String? {
        let normalised = text.precomposedStringWithCanonicalMapping
        var runs: [(token: String, start: String.Index)] = []
        var current: String.Index?
        var index = normalised.startIndex
        func close(at end: String.Index) {
            guard let start = current else { return }
            current = nil
            let token = normalised[start..<end].lowercased()
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !token.isEmpty { runs.append((token, start)) }
        }
        while index < normalised.endIndex {
            let character = normalised[index]
            if character.isLetter || character.isNumber || character == "'" || character == "\u{2019}" {
                if current == nil { current = index }
            } else {
                close(at: index)
            }
            index = normalised.index(after: index)
        }
        close(at: normalised.endIndex)
        guard runs.count > expecting.count, runs.suffix(expecting.count).map(\.token) == expecting else { return nil }
        let cutIndex = runs[runs.count - expecting.count].start
        // Only the end of the kept text is touched, and only what led into the phrase: an opening quote or bracket
        // that touches it ("He said \"stop margin\"") goes with it, then trailing space, then one dash that stood
        // alone ("He said \u{2014} stop margin"). A quote or apostrophe that closes a word, and anything at the start
        // of the text, is the listener's own and stays.
        let touching = Set("\"\u{201C}\u{2018}'([{\u{00AB}")
        var end = cutIndex
        while end > normalised.startIndex {
            let before = normalised.index(before: end)
            guard touching.contains(normalised[before]) else { break }
            end = before
        }
        var kept = String(normalised[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let dashes = Set("\u{2014}\u{2013}-")
        if let last = kept.last, dashes.contains(last) {
            let beforeDash = kept.dropLast()
            if beforeDash.last?.isWhitespace == true {
                kept = String(beforeDash).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return kept.isEmpty ? nil : kept
    }
}

/// The recogniser's results as they arrive, kept short, with the phrase rule run on them (#3940). The window holds
/// the recogniser's current reading of the last few seconds and nothing older, so memory stays flat for a Margin of
/// any length.
///
/// How a result changes it:
/// - A **volatile** result is the recogniser's current guess for the whole unfinished tail. It replaces every word
///   from its start onward, even when it carries no words (a guess revised to nothing retracts the old one, so a stale
///   "stop margin" can't be confirmed). Its start is `resultStartMs`, or its first word's start.
/// - A **final** result replaces only the words inside its own range, so a late final for earlier audio can't delete
///   the newer tail.
public struct MarginEndPhraseWindow: Sendable {
    /// How much of the audio's recent past is kept, plus the one word before it. The rule needs only the phrase and
    /// the word before it (the pause "and martian" needs).
    public static let retainMs = 10_000

    public private(set) var words: [MarginEndPhraseWord] = []

    public init() {}

    /// Takes the next result (none for no new result) and `audioNowMs`, the time through which the recogniser has
    /// delivered results (see `MarginEndPhrase.evaluate`). Gives what the rule says now.
    public mutating func advance(
        audioNowMs: Int,
        hearing batch: [MarginEndPhraseWord] = [],
        isFinal: Bool = false,
        resultStartMs: Int? = nil
    ) -> MarginEndPhrase.Outcome {
        if let start = resultStartMs ?? batch.first?.startMs {
            if isFinal, let last = batch.last {
                let end = max(last.endMs, batch.map(\.endMs).max() ?? 0)
                words.removeAll { $0.startMs >= start && $0.startMs < end }
            } else if !isFinal {
                words.removeAll { $0.startMs >= start }
            }
            words.append(contentsOf: batch)
            words.sort { $0.startMs < $1.startMs }
        }
        // Forget what is older than the window, but keep the last word before it: with it gone, a phrase's pause
        // check would read "nothing came before" for a word that was said right before.
        let cutoff = audioNowMs - Self.retainMs
        if let lastOld = words.lastIndex(where: { $0.endMs < cutoff }), lastOld > 0 {
            words.removeFirst(lastOld)
        }
        return MarginEndPhrase.evaluate(words: words, audioNowMs: audioNowMs)
    }
}
