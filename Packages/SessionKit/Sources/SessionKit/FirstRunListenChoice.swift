import Foundation

/// #2851: what the first-run drawer's Done plays. The listener's first pick wins, whether it is a show or a
/// newsletter, because a pick is the one thing they told us they want; a later pick never outranks it. A
/// pick with nothing to play yet (a feed with no episodes, or every one played) falls through to the next,
/// and when no pick has anything the caller plays the Welcome sample.
public enum FirstRunListenChoice {
    /// The entry to play: the newest unplayed one of the first picked source that has any.
    /// - Parameter pickedSourceIds: the followed sources' ids (`SourceIdentity.id`), in the order they were tapped.
    public static func entry(
        forPickedSourceIds pickedSourceIds: [String],
        subscriptions: [FeedSubscription],
        entries: [FeedEntry]
    ) -> FeedEntry? {
        let rows = FollowingShowRows.build(subscriptions: subscriptions, entries: entries).rows
        for sourceId in pickedSourceIds {
            guard let subscription = subscriptions.first(where: { $0.source.id == sourceId }),
                  let entryId = rows.first(where: { $0.id == subscription.id })?.playEntryID,
                  let entry = entries.first(where: { $0.id == entryId }) else { continue }
            return entry
        }
        return nil
    }
}
