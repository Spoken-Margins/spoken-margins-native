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
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .reverse]) { sentence, _, _, stop in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
            sentences.insert(sentence, at: 0)
            if sentences.count == sentenceLimit { stop = true }
        }
        let joined = sentences.joined(separator: " ")
        if joined.count <= characterLimit { return joined.isEmpty ? nil : joined }
        // Longer than the cue allows: keep the end, which is what was heard last, starting at a word.
        let tail = String(joined.suffix(characterLimit))
        let fromWord = tail.drop(while: { !$0.isWhitespace }).drop(while: \.isWhitespace)
        return fromWord.isEmpty ? nil : "…" + fromWord
    }
}
