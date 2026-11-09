import Foundation

/// When Following counts a followed episode as heard, so its row previews the next one and drops the ▶ (#3691).
/// The Library's own "finished" needs 99% (credits and outros keep an episode just short of it), so Following reads
/// a wider rule: heard from 95%, or once playback is within the last two minutes, whichever comes first.
/// Pure: the caller passes the item, its sessions and the feed's duration for the episode.
public enum FollowingHeardRule {
    /// Heard from this share of the way through.
    public static let heardPercent = 95
    /// Heard once this little is left to play.
    public static let lastStretchMs = 120_000
    /// The last-stretch rule applies only past this share of the episode, so a three-minute clip is not "heard"
    /// at its first minute. The session's own percent (measured by the player on the real audio) must agree, so a
    /// feed duration that is shorter than the audio, as with inserted ads, cannot make an unheard episode heard.
    public static let lastStretchStartsAtFraction = 0.5
    static let lastStretchStartsAtPercent = 50

    public static func isHeard(item: LibraryItemSummary, sessions: [Session], entryDurationMs: Int? = nil) -> Bool {
        if item.sourceCompletedAt != nil || PreparationChunkGate.itemAlreadyListened(sessions) { return true }
        // Either duration may be 0 or missing; the item's own comes first, the feed's is the fallback.
        let durationMs = [item.media?.durationMs, entryDurationMs].compactMap { $0 }.first { $0 > 0 }
        return sessions.contains { session in
            session.completionPercent >= heardPercent || isInLastStretch(session, durationMs: durationMs)
        }
    }

    static func isInLastStretch(_ session: Session, durationMs: Int?) -> Bool {
        guard let durationMs, durationMs > 0, let positionMs = session.position.mediaTimeMs,
              session.completionPercent >= lastStretchStartsAtPercent else { return false }
        return Double(positionMs) >= Double(durationMs) * lastStretchStartsAtFraction
            && durationMs - positionMs <= lastStretchMs
    }
}
