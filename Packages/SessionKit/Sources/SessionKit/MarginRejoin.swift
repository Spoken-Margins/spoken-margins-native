import Foundation

/// Where a source picks up after a saved Margin (#776). The listener hears the end of the thought
/// again instead of landing mid-word: media steps back a few seconds, and text goes back to the
/// start of the sentence that was playing. Only the resume position moves; the Margin keeps the
/// anchor it was made at.
enum MarginRejoin {
    /// How far a podcast or other media source steps back when a Margin is saved.
    static let mediaStepBackMs = 3_000

    /// The media time to resume at after a Margin made at `pausedAtMs`, never before 0:00.
    static func mediaResumeTimeMs(pausedAtMs: Int) -> Int {
        max(0, pausedAtMs - mediaStepBackMs)
    }

    /// The start of the sentence holding `offset` in `text`. An offset that is already a sentence
    /// start stays where it is, so several Margins in one sentence never drift back into the
    /// sentence before it.
    ///
    /// A sentence ends at a line break, or at ".", "?" or "!" (and any closing quotes or brackets after
    /// it) followed by whitespace or the end of the text, so the point in "3.14" or "example.com" is not
    /// an end. The next sentence starts after the whitespace that follows.
    static func textResumeOffset(pausedAt offset: Int, in text: String) -> Int {
        let chars = Array(text)
        let clamped = max(0, min(offset, chars.count))
        var index = min(clamped, chars.count - 1)
        while index >= 0 {
            var start: Int?
            if chars[index].isNewline {
                start = index + 1
            } else if sentenceEnds.contains(chars[index]) {
                var after = index + 1
                while after < chars.count, closers.contains(chars[after]) { after += 1 }
                if after == chars.count || chars[after].isWhitespace { start = after }
            }
            if var start {
                while start < chars.count, chars[start].isWhitespace { start += 1 }
                if start <= clamped { return start }
            }
            index -= 1
        }
        return 0
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
}
