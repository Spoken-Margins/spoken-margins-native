import Foundation

/// What a press of Next chapter does (#569).
///
/// When the chapter being left has a ready scene summary, Next chapter plays that summary
/// (the same audio Skim forward plays) and then lands at the next chapter's start, so a
/// chapter stop still lands at the chapter start (#458/#460). A second press while that
/// summary plays skips the rest of it and lands at once. Presses don't queue summaries.
public enum NextChapterPress: Equatable, Sendable {
    /// A summary heading for the next chapter is playing: stop it and land there now.
    case skipSummary
    /// Play the summary of the chapter being left, then land at `landingMs`, the next chapter's start.
    case summaryThenJump(landingMs: Int)
    /// No summary for the chapter being left: today's plain jump.
    case jump
    /// Nothing to move to, or a summary heading somewhere else is playing.
    case unavailable
}

public enum NextChapterSummaryRule {
    /// A summary counts as the one for the chapter being left only when the scene it summarises
    /// ends at the next chapter's start, give or take this much. Feed chapters and map scenes
    /// that don't line up keep the plain jump rather than read a summary of something else.
    public static let alignmentToleranceMs = 1_000

    /// The same rule on a text item, where positions are characters, not milliseconds (#1471): a scene and the
    /// chapter it matches start at the same character, so this only absorbs a stray space at a boundary.
    public static let alignmentToleranceChars = 16

    /// The summary playing now, if any.
    public struct PlayingSummary: Equatable, Sendable {
        public var direction: SkimDirection
        public var landsAtMs: Int
        public init(direction: SkimDirection, landsAtMs: Int) {
            self.direction = direction; self.landsAtMs = landsAtMs
        }
    }

    /// Whether Next chapter is offered at all. It stays offered while a summary heading for the
    /// next chapter plays, so a second press can skip it; other summaries (Skim back, or a Skim
    /// forward to a scene inside the chapter) hide it, as before.
    public static func isAvailable(
        playing: PlayingSummary?, hasNextChapter: Bool, nextChapterStartMs: Int?, tolerance: Int = alignmentToleranceMs
    ) -> Bool {
        guard let playing else { return hasNextChapter }
        return isHeadingForNextChapter(playing, nextChapterStartMs: nextChapterStartMs, tolerance: tolerance)
    }

    /// What fills one side of the chapter row above the scrubber (#1666, which replaced #1628's hide-the-button rule).
    public enum ChapterRowControl: Equatable, Sendable {
        /// Skim to the next (or previous) Margin or scene.
        case skim
        /// The chapter row's own Next chapter button.
        case nextChapter
        /// Next chapter standing in for a Skim that can't be pressed, on an item that has Skim. It is drawn unlike
        /// Skim and says why, so a plain chapter jump never passes for a Skim (#2185).
        case nextChapterInSkimSlot
        /// A Skim control that can't be pressed now (no scene ahead, or the end of the map). It keeps its place so the
        /// title doesn't shift when the listener crosses a chapter.
        case skimDisabled
        /// Nothing: the item has no Skim, so the row is the title and, if there is one, Next chapter.
        case hidden
    }

    /// The control on the right of the chapter title. When forward Skim can be pressed it is the one forward control;
    /// otherwise Next chapter if there is a chapter ahead (marked as standing in for Skim when the item has Skim);
    /// otherwise a disabled Skim so the slot never goes empty.
    /// Only the button depends on Skim: the Lock Screen and external commands go by `isAvailable`. The Skim row can
    /// be on screen for Skim Back alone, so forward Skim counts only when the row is shown and forward is enabled.
    public static func forwardControl(isAvailable: Bool, skimRowShown: Bool, canSkimForward: Bool) -> ChapterRowControl {
        if skimRowShown && canSkimForward { return .skim }
        if isAvailable { return skimRowShown ? .nextChapterInSkimSlot : .nextChapter }
        return skimRowShown ? .skimDisabled : .hidden
    }

    /// The control on the left of the chapter title: Skim back, disabled when there is nowhere to go, and absent
    /// only for an item with no Skim at all.
    public static func backwardControl(skimRowShown: Bool, canSkimBackward: Bool) -> ChapterRowControl {
        guard skimRowShown else { return .hidden }
        return canSkimBackward ? .skim : .skimDisabled
    }

    /// - Parameters:
    ///   - playing: the summary bridge playing now, if any.
    ///   - hasNextChapter: whether the item has a chapter after the current one.
    ///   - nextChapterStartMs: the next chapter's start: its media time, or on a text item its start character (#1471).
    ///     nil when the item has no next chapter to land at.
    ///   - summaryLandsAtMs: where a forward Skim from here would land after its summary;
    ///     nil when the current scene has no ready summary audio.
    ///   - tolerance: how far the summary's landing may sit from the chapter start; `alignmentToleranceChars` on text.
    public static func press(
        playing: PlayingSummary?,
        hasNextChapter: Bool,
        nextChapterStartMs: Int?,
        summaryLandsAtMs: Int?,
        tolerance: Int = alignmentToleranceMs
    ) -> NextChapterPress {
        if let playing {
            return isHeadingForNextChapter(playing, nextChapterStartMs: nextChapterStartMs, tolerance: tolerance)
                ? .skipSummary : .unavailable
        }
        guard hasNextChapter else { return .unavailable }
        guard let nextChapterStartMs, let summaryLandsAtMs,
              aligned(summaryLandsAtMs, nextChapterStartMs, tolerance: tolerance) else { return .jump }
        return .summaryThenJump(landingMs: nextChapterStartMs)
    }

    private static func isHeadingForNextChapter(_ playing: PlayingSummary, nextChapterStartMs: Int?, tolerance: Int) -> Bool {
        guard playing.direction == .forward, let nextChapterStartMs else { return false }
        return aligned(playing.landsAtMs, nextChapterStartMs, tolerance: tolerance)
    }

    private static func aligned(_ a: Int, _ b: Int, tolerance: Int) -> Bool { abs(a - b) <= tolerance }
}
