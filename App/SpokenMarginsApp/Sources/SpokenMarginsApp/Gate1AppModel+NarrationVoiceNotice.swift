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
