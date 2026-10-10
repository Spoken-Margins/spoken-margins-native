import Foundation

/// What a press of Next chapter does (#569).
///
/// When the chapter being left has a ready scene summary, Next chapter plays that summary
/// (the same audio Skim forward plays) and then lands at the next chapter's start, so a
/// chapter stop still lands at the chapter start (#458/#460). A second press while that
/// summary plays skips the rest of it and lands at once. Presses don't queue summaries.
public enum NextChapterPress: Equatable, Sendable {
    /// A forward summary is playing: stop it and land where it was heading now.
    case skipSummary
    /// Play the summary of the chapter being left, then land at `landingMs`, the next chapter's start.
    case summaryThenJump(landingMs: Int)
    /// No summary for the chapter being left: today's plain jump.
    case jump
    /// Nothing to move to, or a backward summary is playing.
    case unavailable
}

public enum NextChapterSummaryRule {
    /// A summary counts as the one for the chapter being left only when the scene it summarises
    /// ends at the next chapter's start, give or take this much. Feed chapters and map scenes
    /// that don't line up keep the plain jump rather than read a summary of something else.
    public static let alignmentToleranceMs = 1_000

    /// Whether Next chapter is offered at all. It stays offered while a forward summary plays,
    /// so a second press can skip it.
    public static func isAvailable(playingSummary: SkimDirection?, hasNextChapter: Bool) -> Bool {
        switch playingSummary {
        case .forward: return true
        case .backward: return false
        case nil: return hasNextChapter
        }
    }

    /// - Parameters:
    ///   - playingSummary: the direction of the summary bridge playing now, if any.
    ///   - hasNextChapter: whether the item has a chapter after the current one.
    ///   - nextChapterStartMs: the next chapter's media start; nil for text chapters.
    ///   - summaryLandsAtMs: where a forward Skim from here would land after its summary;
    ///     nil when the current scene has no ready summary audio.
    public static func press(
        playingSummary: SkimDirection?,
        hasNextChapter: Bool,
        nextChapterStartMs: Int?,
        summaryLandsAtMs: Int?
    ) -> NextChapterPress {
        switch playingSummary {
        case .forward: return .skipSummary
        case .backward: return .unavailable
        case nil: break
        }
        guard hasNextChapter else { return .unavailable }
        guard let nextChapterStartMs, let summaryLandsAtMs,
              abs(summaryLandsAtMs - nextChapterStartMs) <= alignmentToleranceMs else { return .jump }
        return .summaryThenJump(landingMs: nextChapterStartMs)
    }
}
