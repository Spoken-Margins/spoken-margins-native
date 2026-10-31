import Foundation

/// The "Just heard" cue on the recording screen (#1491): the last sentence or two of the source before the place
/// the Margin is anchored to, so the listener can finish the thought they were having. It is cut from the text the
/// anchor already holds for that place, so nothing is read or transcribed for it, and it is absent when the anchor
/// has no words (a podcast with no transcript yet) rather than guessed.
public enum JustHeardCue {
    public static let sentenceLimit = 2
    public static let characterLimit = 220

    public static func excerpt(from anchorBefore: String?) -> String? {
        guard let anchorBefore else { return nil }
        let words = anchorBefore.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let text = words.joined(separator: " ")
        let joined = punctuationSentences(of: text).suffix(sentenceLimit).joined(separator: " ")
        if joined.count <= characterLimit { return joined.isEmpty ? nil : joined }
        // Longer than the cue allows: keep the end, which is what was heard last, starting at a word.
        let tail = String(joined.suffix(characterLimit))
        let fromWord = tail.drop(while: { !$0.isWhitespace }).drop(while: \.isWhitespace)
        return fromWord.isEmpty ? nil : "…" + fromWord
    }

    /// Sentences split after `.`, `!`, `?` or `…` (and any closing quotes or brackets after it) that a space or the
    /// end follows. Text after the last one is a sentence too, so an unpunctuated transcript is one sentence.
    /// Foundation's `.bySentences` did this before, but swift-corelibs-foundation doesn't have it, which broke
    /// SessionKit's Linux build (#2681). It also split at "Dr. ", so this keeps the cue the same on Apple platforms.
    static func punctuationSentences(of text: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?", "…"]
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
        var sentences: [String] = []
        var current = ""
        var ended = false
        for character in text {
            if ended, character.isWhitespace {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
                ended = false
                continue
            }
            current.append(character)
            if terminators.contains(character) {
                ended = true
            } else if !(ended && closers.contains(character)) {
                ended = false
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { sentences.append(last) }
        return sentences
    }
}


/// The "Just heard" words for a podcast Margin, which arrive a second or two after recording starts (#2966). Each
/// recording takes a ticket; words carrying an older ticket belong to a recording that ended or was replaced, and
/// are dropped, so a slow transcription never shows on the next Margin's screen.
public struct JustHeardPeekState: Equatable, Sendable {
    public private(set) var text: String?
    private var generation = 0

    public init() {}

    /// A recording started: forget the last one's words and return the ticket its words must carry.
    public mutating func begin() -> Int {
        generation += 1
        text = nil
        return generation
    }

    /// The recording ended: its words, shown or still coming, are gone.
    public mutating func end() {
        generation += 1
        text = nil
    }

    /// Shows the words if they belong to the current recording. Returns whether anything changed.
    @discardableResult
    public mutating func deliver(_ words: String?, ticket: Int) -> Bool {
        guard ticket == generation, let words, !words.isEmpty, words != text else { return false }
        text = words
        return true
    }
}
