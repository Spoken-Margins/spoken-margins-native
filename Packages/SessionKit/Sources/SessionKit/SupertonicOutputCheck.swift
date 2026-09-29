import Foundation

/// A cheap check that a rendered Supertonic chunk is speech of its text rather than babble (#240).
///
/// Measured on the Mac with voice M2 at speed 1, over prose and a flattened results table:
/// - prose speaks at 13.3–15.3 written characters a second;
/// - every chunk whisper heard as babble ("speaking in a foreign language", or "8-8-8-8…" loops)
///   ran at 5.4–8.2 characters a second, from 10 s up to the 29 s ceiling;
/// - a table chunk that came out mostly readable ran at 9.0.
///
/// Dense numbers read slowly *and* badly, so a slow chunk is the signal. A chunk far faster than
/// prose has lost words. Very short chunks ("Print 11") are too noisy to judge.
public enum SupertonicOutputCheck {
    public static let slowestCharactersPerSecond = 8.5
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
        if rate < slowestCharactersPerSecond {
            return String(format: "too_slow_%.1f_chars_per_s", rate)
        }
        if rate > fastestCharactersPerSecond {
            return String(format: "too_fast_%.1f_chars_per_s", rate)
        }
        return nil
    }
}
