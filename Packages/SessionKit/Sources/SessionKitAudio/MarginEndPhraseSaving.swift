import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

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

    /// A verified cut copy of the Margin's audio, or nil to keep everything. The cut is tried only when all of these hold:
    /// - the Margin was **ended by the phrase** (`endedByPhrase`, from `MarginEndPhraseEndLedger`). A listener who says
    ///   "the end margin" as ordinary words and taps Save, or whose Margin is ended any other way, keeps every word;
    /// - the toggle is on, and there is a transcript and a file;
    /// - the file runs at least `MarginEndPhrase.confirmMs` past the transcript's last word, as the live rule needs
    ///   (a Margin ended by the phrase always does; one ended by a tap right after the words does not);
    /// - the transcript ends with the phrase and the cut verifies (`MarginEndPhraseTrim.prepare`).
    ///
    /// Runs off the main actor (it is `async` and nonisolated) and changes nothing on disk that the listener keeps.
    public static func prepare(
        audioURL: URL?,
        transcript: AlignedInterjectionTranscript?,
        isSwitchedOn: Bool,
        endedByPhrase: Bool
    ) async -> MarginEndPhraseTrim.PreparedEndPhraseTrim? {
        guard isSwitchedOn, endedByPhrase, let audioURL, let transcript, let lastWord = transcript.segments.last else {
            return nil
        }
        #if canImport(AVFoundation)
        guard case .milliseconds(let fileMs) = RecordedFileDuration.measure(audioURL),
              fileMs - lastWord.endMs >= MarginEndPhrase.confirmMs else { return nil }
        return await MarginEndPhraseTrim.prepare(fileURL: audioURL, transcript: transcript)
        #else
        return nil
        #endif
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

/// Which Margins were ended by the spoken phrase, so the cut never touches one that was not (#3940, PR 4).
///
/// The listener marks a Margin the moment the phrase ends it; the transcription job asks once. Nothing is stored:
/// after a relaunch, or on a retry, a Margin is not marked, which keeps all its audio and words. Unmarked is the
/// safe answer, so a Margin ended by the screen, the Lock Screen, a headset press or an interruption is never cut,
/// whatever its last words are.
public final class MarginEndPhraseEndLedger: @unchecked Sendable {
    public static let shared = MarginEndPhraseEndLedger()

    private let lock = NSLock()
    private var ids: Set<String> = []

    public init() {}

    /// Records that the phrase ended this Margin.
    public func markEndedByPhrase(interjectionId: String) {
        lock.withLock { _ = ids.insert(interjectionId) }
    }

    /// True once for a marked Margin, then false: the cut is tried on its first transcription only.
    public func consumeEndedByPhrase(interjectionId: String) -> Bool {
        lock.withLock { ids.remove(interjectionId) != nil }
    }
}
