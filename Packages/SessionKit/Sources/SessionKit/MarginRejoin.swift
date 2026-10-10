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

    /// How a prepared article's narration found its resume time (#806). Kept on the engine's diagnostics
    /// so a rejoin that fell back to a chunk start can be told from one that found the sentence.
    enum PreparedNarrationOutcome: String, Equatable {
        /// The audio is a sentence-start time on the narration timeline.
        case sentenceStart = "sentence_start"
        /// The sentence start had no time on the timeline, so the audio went to the start of the
        /// narration chunk (timeline segment) holding the pause.
        case chunkStart = "chunk_start"
        /// The narration has no timeline at all, so the audio stays where it paused.
        case unmapped = "unmapped"
    }

    /// How far past the pause the text position is read. A pause made right at a sentence start can read
    /// as a character or two before it once times round to characters, and would step back a whole
    /// sentence; reading slightly ahead keeps such a pause on its own sentence.
    static let preparedNarrationLookaheadMs = 100

    /// The time to resume a prepared article's narration at after a Margin made at `pausedAtMs` (#806).
    /// An article's text is read from the start of the sentence that was playing, whether it is spoken
    /// live or played as audio, so this finds that sentence on the narration's timeline. It never steps
    /// back a fixed few seconds: when the sentence has no time it uses the start of the chunk instead.
    static func preparedNarrationResume(
        pausedAtMs: Int, text: String, timeline: TranscriptTimeline
    ) -> (timeMs: Int, outcome: PreparedNarrationOutcome) {
        let pausedAtMs = max(0, pausedAtMs)
        let segments = timeline.segments.sorted { $0.startMs < $1.startMs }
        guard let holding = segments.last(where: { $0.startMs <= pausedAtMs }) ?? segments.first else {
            return (pausedAtMs, .unmapped)
        }
        let chunkStart = holding.startMs
        // A chunk with no text positions can't place a sentence, and reading its offset as 0 would
        // send the listener to the top of the article.
        guard holding.startChar != nil, holding.endChar != nil else {
            return (min(pausedAtMs, chunkStart), .chunkStart)
        }
        // Never read past the last character: the end of the text counts as a sentence start there.
        let pausedOffset = min(
            PreparedNarrationFallback.textOffset(
                mediaTimeMs: pausedAtMs + preparedNarrationLookaheadMs, timeline: timeline
            ),
            max(0, text.count - 1)
        )
        let sentenceStart = textResumeOffset(pausedAt: pausedOffset, in: text)
        if let timeMs = PreparedNarrationFallback.mediaTimeMs(textOffset: sentenceStart, timeline: timeline) {
            return (max(0, min(timeMs, pausedAtMs)), .sentenceStart)
        }
        return (min(pausedAtMs, chunkStart), .chunkStart)
    }

    /// The start of the sentence holding `offset` in `text`. An offset that is already a sentence
    /// start stays where it is, so several Margins in one sentence never drift back into the
    /// sentence before it.
    ///
    /// A sentence ends at a line break, or at ".", "?" or "!" (and any closing quotes or brackets after
    /// it) followed by whitespace or the end of the text, so the point in "3.14" or "example.com" is not
    /// an end. Nor is the period of a title such as "Dr.", or of a short form such as "Jr." or "e.g." when
    /// a lowercase word follows it. The next sentence starts after the whitespace that follows.
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
                if (after == chars.count || chars[after].isWhitespace),
                   !(chars[index] == "." && continuesAfterAbbreviation(chars, period: index, next: after)) {
                    start = after
                }
            }
            if var start {
                while start < chars.count, chars[start].isWhitespace { start += 1 }
                if start <= clamped { return start }
            }
            index -= 1
        }
        return 0
    }

    /// Whether the "." at `period` closes a short form after which the sentence goes on. A title
    /// ("Dr. Smith") always leads into a name, so it never ends a sentence. Other short forms ("Bob Jr.",
    /// "e.g.") can end one, so they continue it only when the next word starts in lowercase.
    private static func continuesAfterAbbreviation(_ chars: [Character], period: Int, next: Int) -> Bool {
        var first = period
        while first > 0, chars[first - 1].isLetter || chars[first - 1] == "." { first -= 1 }
        let word = String(chars[first..<period]).lowercased()
        if titles.contains(word) { return true }
        guard shortForms.contains(word) else { return false }
        var following = next
        while following < chars.count, chars[following].isWhitespace { following += 1 }
        return following < chars.count && chars[following].isLowercase
    }

    /// Titles that come before a name. "St." stays here: "St. James" is more common in speech than a
    /// sentence ending in "Main St.".
    private static let titles: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "rev", "hon", "gen", "gov", "sen", "rep", "capt", "lt", "col",
        "sgt", "mt",
    ]

    /// Short forms that can end a sentence or go on with it. "etc.", "Inc." and "No." are left out:
    /// they end one far more often than not.
    private static let shortForms: Set<String> = ["jr", "sr", "ft", "vs", "e.g", "i.e", "cf", "approx", "vol", "fig"]

    private static let sentenceEnds: Set<Character> = [".", "?", "!"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
}
