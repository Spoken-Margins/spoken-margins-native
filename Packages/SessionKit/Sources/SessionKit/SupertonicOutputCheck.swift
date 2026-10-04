import Foundation

/// A cheap check that a rendered Supertonic chunk is speech of its text rather than babble (#240).
///
/// Measured on the Mac with voice M2 at speed 1, over prose and a flattened results table:
/// - prose speaks at 13.3–15.3 written characters a second;
/// - every chunk whisper heard as babble ("speaking in a foreign language", or "8-8-8-8…" loops)
///   ran at 5.4–8.2 characters a second, from 10 s up to the 29 s ceiling;
/// - a table chunk that came out mostly readable ran at 9.0.
///
/// A chunk far faster than prose has lost words. Very short chunks ("Print 11") are too noisy to judge.
///
/// Slow alone isn't babble (#708). Correct speech of a commit hash, an issue number, a time or a
/// percentage is slow per written character too: "1744dff" is read a letter at a time. Rendered
/// with M2 and transcribed with whisper (small.en), prose holding hashes, issue numbers, times and
/// percentages spoke correctly at 6.9–8.5 characters a second, while every chunk that babbled was a
/// table: three or more numbers in a row with no word between them ("0.8889 91.1% 8.9% 0.0",
/// "$0.021 $0.004 $0.0007"), at 5.5–8.0. So a slow chunk is flagged when it reads like a table, or
/// when it is slower than any correct speech measured.
public enum SupertonicOutputCheck {
    public static let slowestCharactersPerSecond = 8.5
    /// Below this a chunk is flagged even without a run of numbers. Correct speech never measured
    /// under 6.9; babble of prose-like text, if it happens below the length ceiling, would land here.
    public static let slowestUnlessTableCharactersPerSecond = 6.0
    /// Numbers in a row, with no word between them, that make a chunk read like a table.
    static let tableRunLength = 3
    public static let fastestCharactersPerSecond = 30.0
    /// Well below the ~28 s point where every chunk in the owner's PDF babbled.
    public static let longestChunkSeconds = 22.0
    static let shortestJudgedCharacters = 24

    /// Nil when the audio is plausible for `text`; otherwise why it isn't.
    /// `speed` is the synthesis speed the chunk was rendered at.
    public static func problem(text: String, durationSeconds: Double, speed: Double = 1) -> String? {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return "no_audio" }
        let spokenSeconds = durationSeconds * max(0.1, speed)
        if spokenSeconds >= longestChunkSeconds {
            return String(format: "too_long_%.1fs", spokenSeconds)
        }
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard characters >= shortestJudgedCharacters else { return nil }
        let rate = Double(characters) / spokenSeconds
        if rate < slowestUnlessTableCharactersPerSecond
            || (rate < slowestCharactersPerSecond && longestNumberRun(in: text) >= tableRunLength) {
            return String(format: "too_slow_%.1f_chars_per_s", rate)
        }
        if rate > fastestCharactersPerSecond {
            return String(format: "too_fast_%.1f_chars_per_s", rate)
        }
        return nil
    }

    /// The most whitespace-separated tokens holding a digit that follow one another with no word
    /// between them. A word is a token with two or more letters and no digit; a lone letter or
    /// symbol ("s", "=", "σ") doesn't break the run, as units and operators sit between table cells.
    static func longestNumberRun(in text: String) -> Int {
        var run = 0
        var longest = 0
        for token in text.split(whereSeparator: \.isWhitespace) {
            if token.contains(where: \.isNumber) {
                run += 1
                longest = max(longest, run)
            } else if token.filter(\.isLetter).count >= 2 {
                run = 0
            }
        }
        return longest
    }
}
