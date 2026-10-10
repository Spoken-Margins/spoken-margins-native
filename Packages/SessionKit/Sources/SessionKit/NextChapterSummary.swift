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
    public static func isAvailable(playing: PlayingSummary?, hasNextChapter: Bool, nextChapterStartMs: Int?) -> Bool {
        guard let playing else { return hasNextChapter }
        return isHeadingForNextChapter(playing, nextChapterStartMs: nextChapterStartMs)
    }

    /// - Parameters:
    ///   - playing: the summary bridge playing now, if any.
    ///   - hasNextChapter: whether the item has a chapter after the current one.
    ///   - nextChapterStartMs: the next chapter's media start; nil for text chapters.
    ///   - summaryLandsAtMs: where a forward Skim from here would land after its summary;
    ///     nil when the current scene has no ready summary audio.
    public static func press(
        playing: PlayingSummary?,
        hasNextChapter: Bool,
        nextChapterStartMs: Int?,
        summaryLandsAtMs: Int?
    ) -> NextChapterPress {
        if let playing {
            return isHeadingForNextChapter(playing, nextChapterStartMs: nextChapterStartMs) ? .skipSummary : .unavailable
        }
        guard hasNextChapter else { return .unavailable }
        guard let nextChapterStartMs, let summaryLandsAtMs, aligned(summaryLandsAtMs, nextChapterStartMs) else { return .jump }
        return .summaryThenJump(landingMs: nextChapterStartMs)
    }

    private static func isHeadingForNextChapter(_ playing: PlayingSummary, nextChapterStartMs: Int?) -> Bool {
        guard playing.direction == .forward, let nextChapterStartMs else { return false }
        return aligned(playing.landsAtMs, nextChapterStartMs)
    }

    private static func aligned(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= alignmentToleranceMs }
}
