import Foundation
import SessionKit

/// How a finished spoken Margin's transcription job uses `MarginEndPhraseTrim` (#3940, PR 4 of the Design).
///
/// The job stays in the app model; this holds the three decisions so they are host-tested: whether to try the cut,
/// which words to save, and whether the cut audio replaces the original once the words are saved. Every "no" keeps
/// the full audio and the full words: losing the listener's speech is worse than keeping two spoken words.
public enum MarginEndPhraseSaving {
    /// The Settings toggle's storage key (`@AppStorage("marginEndPhrase")`); on until the listener turns it off.
    public static let settingsKey = "marginEndPhrase"

    /// The toggle as stored: absent means on.
    public static func isSwitchedOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingsKey) as? Bool ?? true
    }

    /// A verified cut copy of the Margin's audio, or nil to keep everything: the toggle is off, there is no
    /// transcript or file, the transcript doesn't end with the phrase, or the cut failed. Runs off the main actor
    /// (it is `async` and nonisolated), and changes nothing on disk that the listener keeps.
    public static func prepare(
        audioURL: URL?,
        transcript: AlignedInterjectionTranscript?,
        isSwitchedOn: Bool
    ) async -> MarginEndPhraseTrim.PreparedEndPhraseTrim? {
        guard isSwitchedOn, let audioURL, let transcript else { return nil }
        return await MarginEndPhraseTrim.prepare(fileURL: audioURL, transcript: transcript)
    }

    /// The words to save: the prepared cut's, or the heard ones.
    public static func wordsToSave(
        heard: AlignedInterjectionTranscript?,
        prepared: MarginEndPhraseTrim.PreparedEndPhraseTrim?
    ) -> AlignedInterjectionTranscript? {
        prepared?.transcript ?? heard
    }

    /// Call once the words are saved, or failed to save. Saved: the cut audio replaces the original. Not saved: the
    /// cut copy is thrown away and the original stays, so audio and words still agree.
    public static func finish(_ prepared: MarginEndPhraseTrim.PreparedEndPhraseTrim?, wordsSaved: Bool) {
        guard let prepared else { return }
        if wordsSaved {
            prepared.swapIn()
        } else {
            prepared.throwAway()
        }
    }
}
