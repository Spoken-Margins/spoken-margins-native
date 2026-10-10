import AVFoundation
import Foundation
import SessionKit

/// The player's notice when the narration guard swaps in the iOS voice for a passage (#306).
extension Gate1AppModel {
    var playbackChapterHeaderTitle: String? {
        if let notice = narrationVoiceNotice.chapterLine { return notice }
        let itemTitle = playbackItemHeaderTitle
        let combined = playbackHeaderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty,
              combined.caseInsensitiveCompare(itemTitle) != .orderedSame else {
            return nil
        }
        return combined
    }

    func updateNarrationVoiceNotice() {
        var notice = narrationVoiceNotice
        let banner = notice.update(
            snapshot: snapshot,
            replacementTargetId: (speechPlaybackClient as? SupertonicSpeechPlaybackClient)?.replacementVoiceTargetId
        )
        if notice != narrationVoiceNotice { narrationVoiceNotice = notice }
        if let banner { presentFeedback(UserFeedbackEvent(kind: .warning, message: banner)) }
    }
}

/// The chime that introduces the iOS voice when it takes over a passage from the chosen voice (#934). It is the
/// playback start chime, so the app ships no new sound. Like that chime it never configures the audio session: it
/// plays only when narration has already put the session in its `.playback` category, which it has when a passage
/// follows another one.
final class NarrationVoiceChangeChime: @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayer?

    /// Returns what it did, for tests and diagnostics: "played" or "skipped:<why>".
    @discardableResult
    func play() -> String {
        #if os(iOS)
        guard AVAudioSession.sharedInstance().category == .playback else { return "skipped:session_not_playback" }
        #endif
        do {
            let chime = try AVAudioPlayer(data: PlaybackStartChime.wavData())
            chime.volume = 1
            lock.withLock { player = chime }
            return chime.play() ? "played" : "skipped:player_refused"
        } catch {
            return "skipped:\(error.localizedDescription)"
        }
    }
}
