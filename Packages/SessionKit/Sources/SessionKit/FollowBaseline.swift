import Foundation

/// What counts as New when a feed is followed (#1589). Following a show with a long back catalogue
/// must not fill the New list with its old episodes: an entry is New only if the feed published it
/// after the listener followed it. Everything the feed already had stays stored, so the show's own
/// page can still list it, but it never reaches the cross-feed New list.
public enum FollowBaseline {
    /// Whether `entry` was already in the feed before `subscription` was followed.
    ///
    /// 1. An entry stamped with the follow moment (or earlier) was in the feed's first fetch. That
    ///    holds whatever date it claims: a feed that stamps every episode with today's date is still
    ///    back catalogue.
    /// 2. Otherwise a publish date before the follow moment is back catalogue. This also covers an
    ///    old episode a feed lists late, and entries saved before `firstSeenAt` existed.
    /// 3. An entry with neither can't be placed, so it counts as new.
    public static func isBackCatalogue(_ entry: FeedEntry, of subscription: FeedSubscription) -> Bool {
        if let seen = entry.firstSeenAt, seen <= subscription.createdAt { return true }
        if let published = entry.publishedAt { return published < subscription.createdAt }
        return false
    }

    /// The entries New may list: `entries` without the back catalogue of the subscriptions listed.
    /// An entry whose subscription isn't listed is kept, as it was before the baseline.
    public static func newEntries(_ entries: [FeedEntry], subscriptions: [FeedSubscription]) -> [FeedEntry] {
        guard !subscriptions.isEmpty else { return entries }
        let byID = Dictionary(subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { entry in
            guard let subscription = byID[entry.subscriptionId] else { return true }
            return !isBackCatalogue(entry, of: subscription)
        }
    }

    /// The `firstSeenAt` a saved entry carries. An entry already stored keeps its own stamp, nil
    /// included, so a refresh or relaunch never moves it past the follow moment. A new entry gets
    /// `followMoment` when it comes from the fetch that followed the feed (`followMoment` is nil
    /// on every later refresh), else `now`.
    public static func firstSeenAt(existing: FeedEntry?, followMoment: Date?, now: Date) -> Date? {
        if let existing { return existing.firstSeenAt }
        return followMoment ?? now
    }
}
