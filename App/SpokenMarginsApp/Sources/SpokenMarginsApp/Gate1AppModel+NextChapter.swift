import Foundation
import SessionKit

/// Next chapter (#569): moved out of `Gate1AppModel.swift` with the summary-first behaviour, to keep that
/// file under its size ceiling (scripts/hot_file_ratchet.py). The decision is `NextChapterSummaryRule`
/// in SessionKit; this is the wiring to the model's chapters and Skim bridge.
extension Gate1AppModel {
    var canJumpToNextChapter: Bool {
        let mediaChapter = nextPlaybackChapter == nil ? nextPlaybackMediaChapter : nil
        return !recordingNavigationIsLocked && playingImportedCommentary == nil
            && NextChapterSummaryRule.isAvailable(
                playing: playingSummaryForNextChapter,
                hasNextChapter: nextPlaybackChapter != nil || mediaChapter != nil,
                nextChapterStartMs: mediaChapter?.startMs)
    }

    /// Whether the Skim row under the transport is on screen. `PlaybackScreen` draws the row from this, and
    /// `showsNextChapterButton` reads it, so the two controls cannot disagree (#1628).
    var showsSkimRow: Bool {
        isMediaPlaybackSnapshot
            && (snapshot.canSkimBackward || snapshot.canSkimForward || snapshot.skimBridgeState != nil)
    }

    /// Whether the chapter row above the scrubber shows its Next chapter button. A forward Skim control that can
    /// be pressed already offers forward navigation, so the second button is hidden; with no forward Skim target
    /// (no ready map, or the end of it) Next chapter stays. Only the button depends on Skim: the Lock Screen and
    /// external commands go by `canJumpToNextChapter`, and the second press of #569 still works through Skim,
    /// which ends the playing summary the same way (#1628).
    var showsNextChapterButton: Bool {
        NextChapterSummaryRule.showsChapterRowButton(
            isAvailable: canJumpToNextChapter, forwardSkimOffered: showsSkimRow && snapshot.canSkimForward)
    }

    private var playingSummaryForNextChapter: NextChapterSummaryRule.PlayingSummary? {
        snapshot.skimBridgeState.map { .init(direction: $0.direction, landsAtMs: $0.destinationMediaTimeMs) }
    }

    /// Reads the summary of the chapter being left, when it has one, then lands at the next
    /// chapter; a second press during the summary skips it (#569, `NextChapterSummaryRule`).
    func jumpToNextChapter() {
        guard canJumpToNextChapter else { return }
        let textChapter = nextPlaybackChapter
        let mediaChapter = textChapter == nil ? nextPlaybackMediaChapter : nil
        let summary = snapshot.skimBridgeState == nil && mediaChapter != nil
            ? snapshot.currentMediaTimeMs.flatMap { resolvedSkimPlaybackPlan(direction: .forward, at: $0) } : nil
        switch NextChapterSummaryRule.press(
            playing: playingSummaryForNextChapter,
            hasNextChapter: textChapter != nil || mediaChapter != nil,
            nextChapterStartMs: mediaChapter?.startMs, summaryLandsAtMs: summary?.destinationMediaTimeMs
        ) {
        case .skipSummary: completeSkimBridge()
        case .summaryThenJump(let landingMs):
            // Like the plain jump, playback carries on at the chapter start even if it was paused.
            if let summary { startSkimBridge(summary.landing(at: landingMs), continueAfterSummary: true) }
        case .unavailable: return
        case .jump:
            if let chapter = textChapter { jumpToChapter(chapter) }
            else if let chapter = mediaChapter {
                if selectedItem.mediaChapters.isEmpty { jumpToListeningMapScene(chapter) }
                else { jumpToMediaChapter(chapter) }
            }
        }
    }

    /// The Live Activity's Next chapter behaves like the app's: summary first, second press skips it (#569).
    /// True when it was that command and has been handled.
    func handlesLiveActivityNextChapter(_ command: CompactControlCommand, chapterId: String?) -> Bool {
        guard command == .jumpToChapter, isMediaPlaybackSnapshot, canJumpToNextChapter,
              let chapterId, chapterId == nextPlaybackMediaChapter?.id else { return false }
        jumpToNextChapter()
        return true
    }
}
