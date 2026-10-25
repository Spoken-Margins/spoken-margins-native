import Foundation
import SessionKit

/// Following's one-row-per-show list and the Show screen (#1865). The rows are built in
/// `FollowingShowRows` (SessionKit, host-tested); this file loads their inputs and carries the actions.
extension Gate1AppModel {
    /// Where the "last looked" times live: a side file next to Following's other per-listener preferences,
    /// not the database, so an older build still opens everything (it never reads this file).
    nonisolated static var followingLookedURL: URL? {
        FollowingRankingModel.directory?.appending(path: FollowingLookedMarkers.fileName, directoryHint: .notDirectory)
    }

    /// The rows Following shows now. Cheap: the entries are already in memory.
    func followingShowList() -> FollowingShowList {
        FollowingShowRows.build(
            subscriptions: feedSubscriptions,
            entries: followingShowEntries,
            lookedAt: followingLooked.lookedAt
        )
    }

    /// Reads every stored entry off the main thread (feeds keep up to 200 each) and the saved looked times
    /// once. Muted shows and played episodes are in it, unlike `followedSourceEntries`.
    func reloadFollowingShowEntries() async {
        guard let store else { return }
        let url = Self.followingLookedURL
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? store.loadFeedEntries(subscriptionId: nil)) ?? []
        }.value
        followingShowEntries = loaded
        if followingLooked.lookedAt.isEmpty, let url {
            let saved = await Task.detached(priority: .utility) { FollowingLookedMarkers.load(from: url) }.value
            // A show opened while the file was loading keeps its newer time.
            var merged = saved
            for (id, date) in followingLooked.lookedAt { merged.markLooked(id, at: max(date, saved.lookedAt[id] ?? date)) }
            followingLooked = merged
        }
    }

    /// The listener opened the show: what has arrived so far is no longer new.
    func markShowLooked(id: String) {
        followingLooked.markLooked(id)
        saveFollowingLooked()
    }

    private func saveFollowingLooked() {
        guard let url = Self.followingLookedURL else { return }
        var pruned = followingLooked
        pruned.prune(keeping: Set(feedSubscriptions.map(\.id)))
        let markers = pruned
        Task.detached(priority: .utility) { try? markers.save(to: url) }
    }

    /// ▶ on a row: plays the show's newest unplayed episode. It enters the Library as it starts and not before.
    func playNewestEpisode(of row: FollowingShowRow) {
        guard let id = row.playEntryID, let entry = followingShowEntries.first(where: { $0.id == id }) else { return }
        importFollowedSourceEntry(entry, playWhenFinished: true)
    }

    /// Unfollow from the Show screen: the show goes at once and the banner offers Undo, which follows the
    /// same feed again, so the button takes one tap (Following > show row > Unfollow). Episodes already in the
    /// Library are kept either way. Undo brings back the show and its newest episodes, not its Quiet or
    /// "new items" choices.
    func unfollowShowWithUndo(_ subscription: FeedSubscription) {
        let title = subscription.source.title ?? subscription.source.host
        let feedURL = subscription.source.canonicalURL
        unfollowSource(id: subscription.id)
        let action = UserFeedbackEvent.Action(
            title: FollowingDismissMessages.undoTitle,
            accessibilityLabel: FollowingRowActions.undoUnfollowAccessibilityLabel(showTitle: title),
            identifier: "following.undo.button",
            perform: { [weak self] in
                Task { [weak self] in _ = try? await self?.followCatalogFeed(feedURL) }
            }
        )
        presentFeedback(UserFeedbackEvent(
            kind: .success, message: FollowingRowActions.unfollowedMessage(showTitle: title), action: action
        ))
    }
}
