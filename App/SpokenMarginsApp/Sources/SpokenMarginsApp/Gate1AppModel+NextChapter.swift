import Foundation
import SessionKit

/// Next chapter (#569): moved out of `Gate1AppModel.swift` with the summary-first behaviour, to keep that
/// file under its size ceiling (scripts/hot_file_ratchet.py). The decision is `NextChapterSummaryRule`
/// in SessionKit; this is the wiring to the model's chapters and Skim bridge.
extension Gate1AppModel {
    var canJumpToNextChapter: Bool {
        let textChapter = nextPlaybackChapter
        let mediaChapter = textChapter == nil ? nextPlaybackMediaChapter : nil
        return !recordingNavigationIsLocked && playingImportedCommentary == nil
            && NextChapterSummaryRule.isAvailable(
                playing: playingSummaryForNextChapter,
                hasNextChapter: textChapter != nil || mediaChapter != nil,
                nextChapterStartMs: textChapter?.startChar ?? mediaChapter?.startMs,
                tolerance: nextChapterTolerance)
    }

    /// Text chapters are placed by character and media chapters by time, so the summary-first rule compares them in
    /// their own unit (#1471).
    private var nextChapterTolerance: Int {
        isTextReadingSnapshot ? NextChapterSummaryRule.alignmentToleranceChars : NextChapterSummaryRule.alignmentToleranceMs
    }

    /// Whether this item has Skim controls at all (a podcast with a ready map, or a Skim summary playing). The chapter
    /// row draws them either side of the title and keeps both in place, dimmed when there is nowhere to go (#1666).
    /// A mapped item keeps them even where neither direction can be pressed, so Next chapter is never mistaken for
    /// Skim there (#2185).
    var showsSkimRow: Bool {
        (isMediaPlaybackSnapshot || isTextReadingSnapshot)
            && (snapshot.canSkimBackward || snapshot.canSkimForward || snapshot.skimBridgeState != nil
                || skimBridge.itemHasMap)
    }

    /// What the chapter row draws right of the title: forward Skim when it can be pressed, else Next chapter, else a
    /// dimmed Skim, so the slot is never empty. The Lock Screen and external commands go by `canJumpToNextChapter`,
    /// and the second press of #569 still works through Skim, which ends the playing summary the same way (#1666).
    var chapterRowForwardControl: NextChapterSummaryRule.ChapterRowControl {
        NextChapterSummaryRule.forwardControl(
            isAvailable: canJumpToNextChapter, skimRowShown: showsSkimRow, canSkimForward: snapshot.canSkimForward)
    }

    /// What the chapter row draws left of the title: Skim back, dimmed when there is nowhere to go.
    var chapterRowBackwardControl: NextChapterSummaryRule.ChapterRowControl {
        NextChapterSummaryRule.backwardControl(skimRowShown: showsSkimRow, canSkimBackward: snapshot.canSkimBackward)
    }

    private var playingSummaryForNextChapter: NextChapterSummaryRule.PlayingSummary? {
        snapshot.skimBridgeState.map { .init(direction: $0.direction, landsAtMs: $0.destinationMediaTimeMs) }
    }

    /// The chapter row's Next chapter button. Where it stands in for a Skim that can't be pressed, the press is logged
    /// as Skim's fallback with the reason, and the listener is told why it was a plain jump (#2185).
    func nextChapterFromChapterRow() {
        let standsInForSkim = chapterRowForwardControl == .nextChapterInSkimSlot
        let reason = skimBridge.forwardUnavailableReason ?? .noSceneSummary
        jumpToNextChapter()
        guard standsInForSkim else { return }
        recordDeveloperDiagnostic(
            "skim.press", SkimPressOutcome.fellBackToChapter.diagnosticFields(direction: .forward, reason: reason.rawValue))
        reportSuccess("Next chapter. \(reason.message)")
    }

    /// Reads the summary of the chapter being left, when it has one, then lands at the next
    /// chapter; a second press during the summary skips it (#569, `NextChapterSummaryRule`).
    func jumpToNextChapter() {
        guard canJumpToNextChapter else { return }
        let textChapter = nextPlaybackChapter
        let mediaChapter = textChapter == nil ? nextPlaybackMediaChapter : nil
        // The playhead the summary is resolved from: a character offset on a text item, a media time otherwise (#1471).
        let playhead = textChapter != nil ? snapshot.currentTextStart : (mediaChapter != nil ? snapshot.currentMediaTimeMs : nil)
        let summary = snapshot.skimBridgeState == nil
            ? playhead.flatMap { resolvedSkimPlaybackPlan(direction: .forward, at: $0) } : nil
        switch NextChapterSummaryRule.press(
            playing: playingSummaryForNextChapter,
            hasNextChapter: textChapter != nil || mediaChapter != nil,
            nextChapterStartMs: textChapter?.startChar ?? mediaChapter?.startMs, summaryLandsAtMs: summary?.destinationMediaTimeMs,
            tolerance: nextChapterTolerance
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
        let nextChapterId = isTextReadingSnapshot ? nextPlaybackChapter?.id : nextPlaybackMediaChapter?.id
        guard command == .jumpToChapter, isMediaPlaybackSnapshot || isTextReadingSnapshot, canJumpToNextChapter,
              let chapterId, chapterId == nextChapterId else { return false }
        jumpToNextChapter()
        return true
    }
}
