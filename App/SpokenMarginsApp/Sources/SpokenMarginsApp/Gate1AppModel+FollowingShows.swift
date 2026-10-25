import Foundation
import SessionKit

/// Writes the looked-times file one save at a time, newest value last: a save that was queued earlier but
/// runs later is dropped, so a stale snapshot can never overwrite a newer one.
actor FollowingLookedWriter {
    static let shared = FollowingLookedWriter()
    private var lastVersion = -Double.infinity

    func save(_ markers: FollowingLookedMarkers, to url: URL, version: Double) {
        guard version >= lastVersion else { return }
        lastVersion = version
        try? markers.save(to: url)
    }
}

/// Following's one-row-per-show list and the Show screen (#1865). The rows are built in
/// `FollowingShowRows` (SessionKit, host-tested); this file loads their inputs and carries the actions.
extension Gate1AppModel {
    /// Where the "last looked" times live: a side file next to Following's other per-listener preferences,
    /// not the database, so an older build still opens everything (it never reads this file).
    nonisolated static var followingLookedURL: URL? {
        FollowingRankingModel.directory?.appending(path: FollowingLookedMarkers.fileName, directoryHint: .notDirectory)
    }

    /// Loads the looked times once, before anything can save them. The file is a few hundred bytes. With no
    /// file, or one that can't be read, every followed show is stamped "now" so nothing counts as new until a
    /// later refresh brings an episode, and that is saved.
    func loadFollowingLookedIfNeeded() {
        guard !followingLookedLoaded else { return }
        followingLookedLoaded = true
        guard let url = Self.followingLookedURL else { return }
        if let saved = FollowingLookedMarkers.loadIfPresent(from: url) {
            followingLooked = saved
        } else if !feedSubscriptions.isEmpty {
            var seeded = followingLooked
            seeded.seed(feedSubscriptions.map(\.id))
            followingLooked = seeded
            saveFollowingLooked()
        }
    }

    /// Reads every stored entry off the main thread (feeds keep up to 200 each), then builds the rows there
    /// too. Muted shows and played episodes are in it, unlike `followedSourceEntries`.
    func reloadFollowingShowEntries() async {
        guard let store else { return }
        loadFollowingLookedIfNeeded()
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? store.loadFeedEntries(subscriptionId: nil)) ?? []
        }.value
        followingShowEntries = loaded
        followingShowRevision += 1
        await rebuildFollowingShowList()
    }

    /// Builds the rows from the current inputs off the main thread; `body` only reads the result.
    func rebuildFollowingShowList() async {
        let subscriptions = feedSubscriptions, entries = followingShowEntries, looked = followingLooked.lookedAt
        let list = await Task.detached(priority: .userInitiated) {
            FollowingShowRows.build(subscriptions: subscriptions, entries: entries, lookedAt: looked)
        }.value
        followingShowListCache = list
    }

    /// The listener opened the show: what has arrived so far is no longer new.
    func markShowLooked(id: String) {
        guard feedSubscriptions.contains(where: { $0.id == id }) else { return }
        loadFollowingLookedIfNeeded()
        followingLooked.markLooked(id)
        saveFollowingLooked()
        Task { [weak self] in await self?.rebuildFollowingShowList() }
    }

    private func saveFollowingLooked() {
        guard let url = Self.followingLookedURL else { return }
        var pruned = followingLooked
        pruned.prune(keeping: Set(feedSubscriptions.map(\.id)))
        let markers = pruned
        let version = ProcessInfo.processInfo.systemUptime
        Task { await FollowingLookedWriter.shared.save(markers, to: url, version: version) }
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
        followingLooked.remove(subscription.id)
        unfollowSource(id: subscription.id)
        saveFollowingLooked()
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
