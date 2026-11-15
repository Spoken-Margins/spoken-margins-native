import Foundation

/// What Play does with a friend's Margins on an item, decided once (#4347, audit findings 1 and 2 on #4248).
///
/// A podcast Margin plays one of three ways (#3789, #4244): in place as the episode reaches it, at the sender's rough
/// time the same way, or after the others, when the episode ends. This is the one place that says which Margins a start
/// would skip, so the Library row's question (`PlayRule.decide`), the item screen's "Hear … first"
/// (`PlayRule.marginsBehindSavedPlace`) and `SharedMarginReview.entriesBehind` can't disagree.
///
/// A Margin that plays after the others is never skipped by a start: reaching the end plays it
/// (`episodeEndReached`). It counts as behind only when the place Play resumes is the end itself, where there is
/// nothing left to play it in, or when the place isn't known and nothing can be ruled out.
public enum FriendMarginsPlan {
    /// Where Play puts the listener.
    public enum Place: Equatable, Sendable {
        /// Not known without reading more (a Library row holds only a percentage): every Margin counts as behind.
        case unknown
        /// A place in the media. `isAtEnd` is true when it is the end of the episode, a session left at 99%.
        case known(mediaTimeMs: Int, isAtEnd: Bool)
    }

    /// The Margins split by what a start at `place` does with them.
    public struct Split: Equatable, Sendable {
        /// The start would skip these: Play asks about them, or the item screen offers to hear them first.
        public let behind: [SharedMarginReview.Entry]
        /// These play in place as the episode reaches them, with no question (#3059).
        public let ahead: [SharedMarginReview.Entry]
        /// These play after the others, when the episode ends. A subset of `ahead` or of `behind` by place; listed
        /// apart because they wait for the end, not for a time.
        public let playAtEnd: [SharedMarginReview.Entry]
    }

    public static func isBehind(_ entry: SharedMarginReview.Entry, place: Place) -> Bool {
        switch place {
        case .unknown: return true
        case .known(let mediaTimeMs, let isAtEnd):
            // Its `mediaTimeMs` is only where the others end (or 0 when the episode's length isn't known), so it says
            // nothing about whether the place is past it.
            return entry.playsAfterOthers ? isAtEnd : entry.mediaTimeMs < mediaTimeMs
        }
    }

    public static func split(_ entries: [SharedMarginReview.Entry], place: Place) -> Split {
        let behind = entries.filter { isBehind($0, place: place) }
        let behindIDs = Set(behind.map(\.marginId))
        return Split(
            behind: behind,
            ahead: entries.filter { !behindIDs.contains($0.marginId) },
            playAtEnd: entries.filter(\.playsAfterOthers))
    }

    public static func behind(_ entries: [SharedMarginReview.Entry], place: Place) -> [SharedMarginReview.Entry] {
        entries.filter { isBehind($0, place: place) }
    }

    /// The tick on which the episode's playback reaches its end, for the same item and session. Two ways to say so, the
    /// ones the app already uses for "completed current audio": progress goes from below the end to the end, or the
    /// source stops at the end after playing (`previous` playing, `current` paused, at `ItemFinishedRule.atEndPercent`).
    /// The second matters because a seek or a lifecycle sync writes the snapshot itself, so the next tick can see
    /// progress already at the end before it sees the source stop. A different item or session says nothing:
    /// opening a finished item must not play its Margins that wait for the end.
    public static func episodeEndReached(previous: SessionSnapshot, current: SessionSnapshot) -> Bool {
        guard previous.itemId != nil, previous.itemId == current.itemId, previous.sessionId == current.sessionId,
              current.currentPlaybackProgressPercent >= ItemFinishedRule.atEndPercent else { return false }
        return previous.currentPlaybackProgressPercent < ItemFinishedRule.atEndPercent
            || (previous.status.isPlaybackActive && current.status == .paused)
    }
}
