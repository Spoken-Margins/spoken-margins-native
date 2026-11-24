import Foundation
import SessionKit
import SessionKitPersistence

/// Following's stored state (#1865), held as one value so `Gate1AppModel.swift` doesn't grow (hot-file ratchet).
struct FollowingShowsState {
    /// Every stored entry of the followed shows, muted shows and played episodes included, for Following's rows and a show's screen.
    var entries: [FeedEntry] = []
    /// When each show was last opened; "N new" on Following counts from it.
    var looked = FollowingLookedMarkers()
    /// Which imported episodes are in the Library and whether each is finished; a row previews the next one worth hearing.
    var libraryEpisodes: [String: FollowingLibraryEpisode] = [:]
    /// The listener's rules, lists and Show less marks (#4046), which set episodes aside before a row is built. Empty until
    /// the first read, and while none is on, Following is exactly what it was without them.
    var ruleInputs = FollowingRuleInputs()
    /// Following's rows, built off the main thread whenever the entries, shows or looked times change.
    var listCache = FollowingShowList()
    /// Counts reloads of `entries`, so a Show screen knows when to rebuild its episodes.
    var revision = 0
    var lookedLoaded = false
    var lookedDirty = false
    /// True once `reloadFollowingShowEntries` has finished a first time. Until then `listCache` is empty, not "no shows",
    /// so Following draws nothing rather than friends alone that the shows would then push down (#3753).
    var listLoaded = false
}

extension Gate1AppModel {
    var followingShowEntries: [FeedEntry] { get { followingShows.entries } set { followingShows.entries = newValue } }
    var followingLooked: FollowingLookedMarkers { get { followingShows.looked } set { followingShows.looked = newValue } }
    var followingLibraryEpisodes: [String: FollowingLibraryEpisode] { get { followingShows.libraryEpisodes } set { followingShows.libraryEpisodes = newValue } }
    var followingRuleInputs: FollowingRuleInputs { get { followingShows.ruleInputs } set { followingShows.ruleInputs = newValue } }
    var followingShowListCache: FollowingShowList { get { followingShows.listCache } set { followingShows.listCache = newValue } }
    var followingShowRevision: Int { get { followingShows.revision } set { followingShows.revision = newValue } }
    var followingLookedLoaded: Bool { get { followingShows.lookedLoaded } set { followingShows.lookedLoaded = newValue } }
    var followingLookedDirty: Bool { get { followingShows.lookedDirty } set { followingShows.lookedDirty = newValue } }
    var followingShowListLoaded: Bool { get { followingShows.listLoaded } set { followingShows.listLoaded = newValue } }
}

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

    /// Reads every stored entry, the looked-times file and the followed shows off the main thread (feeds keep up to
    /// 200 each), then builds the rows there too. Muted shows and played episodes are in it, unlike
    /// `followedSourceEntries`. The first read of a launch settles the markers with
    /// `FollowingLookedMarkers.afterFirstLoad`, against the store's followed shows rather than `feedSubscriptions`
    /// (still empty before the first feed refresh), and saves them if they differ from the file. Until then,
    /// `markShowLooked` only updates memory and sets `followingLookedDirty`. If the followed shows can't be read,
    /// nothing is settled and the next reload tries again.
    func reloadFollowingShowEntries() async {
        // No store yet (it opens lazily): not loaded, so Following stays quiet instead of flashing "not following
        // anything". The screen's task re-runs when the Library loads (`libraryCount` is in its key).
        guard let store else { return }
        let needsMarkers = !followingLookedLoaded
        let url = Self.followingLookedURL
        let importedEntries = listeningSignals.importedEntries
        let result = await Task.detached(priority: .userInitiated) {
            let entries = (try? store.loadFeedEntries(subscriptionId: nil)) ?? []
            let saved = needsMarkers ? url.flatMap { FollowingLookedMarkers.loadIfPresent(from: $0) } : nil
            let followed = needsMarkers ? try? store.loadFeedSubscriptions().map(\.id) : nil
            // Only a show with an imported episode needs the Library read: which of them the listener has finished.
            var library: [String: FollowingLibraryEpisode] = [:]
            if entries.contains(where: { $0.state == .imported }),
               let items = try? store.listItemSummaries(), let sessions = try? store.loadSessions() {
                library = FollowingLibraryEpisodes.resolve(
                    entries: entries, items: items, sessions: sessions, importedEntryIds: importedEntries.entryIds())
            }
            // Rules and marks are read with the entries, so a row is never built from new episodes and old rules.
            return (entries, saved, followed, library, FollowingRuleInputs.load(from: store))
        }.value
        followingShowEntries = result.0
        followingLibraryEpisodes = result.3
        followingRuleInputs = result.4
        followingShowRevision += 1
        ListeningRulesState.shared.noteEntriesRevision(followingShowRevision)
        if needsMarkers, !followingLookedLoaded, let followed = result.2 {
            followingLookedLoaded = true
            let settled = FollowingLookedMarkers.afterFirstLoad(inMemory: followingLooked, saved: result.1, followed: followed)
            followingLooked = settled
            if settled != result.1 || followingLookedDirty {
                followingLookedDirty = false
                saveFollowingLooked()
            }
        }
        await rebuildFollowingShowList()
        followingShowListLoaded = true
    }

    /// Builds the rows from the current inputs off the main thread; `body` only reads the result.
    func rebuildFollowingShowList() async {
        let subscriptions = feedSubscriptions, entries = followingShowEntries, looked = followingLooked.lookedAt
        let library = followingLibraryEpisodes, inputs = followingRuleInputs
        let list = await Task.detached(priority: .userInitiated) {
            // The evaluator runs before the rows are built, so a row's preview, date, sort, count, ▶ and swipe all describe
            // the newest episode that is not set aside. With no rule on and nothing marked it is empty (#4046).
            let rules = FollowingRuleEvaluation.evaluate(
                subscriptions: subscriptions, entries: entries, inputs: inputs, libraryEpisodes: library)
            return FollowingShowRows.build(
                subscriptions: subscriptions, entries: entries, lookedAt: looked, libraryEpisodes: library, rules: rules)
        }.value
        followingShowListCache = list
    }

    /// The listener opened the show: what has arrived so far is no longer new.
    func markShowLooked(id: String) {
        guard feedSubscriptions.contains(where: { $0.id == id }) else { return }
        followingLooked.markLooked(id)
        if followingLookedLoaded {
            saveFollowingLooked()
        } else {
            followingLookedDirty = true
        }
        Task { [weak self] in await self?.rebuildFollowingShowList() }
    }

    private func saveFollowingLooked() {
        guard let url = Self.followingLookedURL else { return }
        // No prune here: `feedSubscriptions` may not be loaded yet. The first load prunes against the store, and
        // Unfollow removes its own marker.
        let markers = followingLooked
        let version = ProcessInfo.processInfo.systemUptime
        Task { await FollowingLookedWriter.shared.save(markers, to: url, version: version) }
    }

    /// ▶ on a row: plays the episode the row shows. One already in the Library (started, not finished) resumes there;
    /// any other enters the Library as it starts and not before.
    func playNewestEpisode(of row: FollowingShowRow) {
        if let itemID = row.playItemID {
            startItem(id: itemID)
            return
        }
        guard let id = row.playEntryID, let entry = followingShowEntries.first(where: { $0.id == id }) else { return }
        importFollowedSourceEntry(entry, playWhenFinished: true)
    }

    /// Swipe on a row (#2929): saves the episode the row previews, without opening the show or playing it. Nothing
    /// happens when the show has none or it is in the Library already, and a second swipe while the first is still
    /// fetching is ignored by `importFollowedSourceEntry`, so the item lands in the Library once.
    func addPreviewedEpisode(of row: FollowingShowRow) {
        guard let id = row.addEntryID,
              let entry = followingShowEntries.first(where: { $0.id == id }), entry.state != .imported else { return }
        importFollowedSourceEntry(entry)
    }

    /// Unfollow from the Show screen: the show goes at once and the banner offers Undo, which follows the
    /// same feed again, so the button takes one tap (Following > show row > Unfollow). Episodes already in the
    /// Library are kept either way. Undo brings back the show and its newest episodes, not its Quiet or
    /// "new items" choices.
    func unfollowShowWithUndo(_ subscription: FeedSubscription) {
        let title = subscription.source.title ?? subscription.source.host
        let feedURL = subscription.source.canonicalURL
        // The lists it is in (#4046): the show leaves them, and Undo puts it back.
        let listIDs = FollowListsState.shared.lists(containing: subscription).map(\.id)
        let member = FollowListEditing.member(for: subscription)
        followingLooked.remove(subscription.id)
        unfollowSource(id: subscription.id)
        if followingLookedLoaded { saveFollowingLooked() } else { followingLookedDirty = true }
        let action = UserFeedbackEvent.Action(
            title: FollowingDismissMessages.undoTitle,
            accessibilityLabel: FollowingRowActions.undoUnfollowAccessibilityLabel(showTitle: title),
            identifier: "following.undo.button",
            perform: { [weak self] in
                Task { [weak self] in
                    guard (try? await self?.followCatalogFeed(feedURL)) != nil else { return }
                    await self?.restoreFollowListMembership(member, toLists: listIDs)
                }
            }
        )
        presentFeedback(UserFeedbackEvent(
            kind: .success,
            message: FollowListWords.unfollowedBanner(showTitle: title, wasInAList: !listIDs.isEmpty),
            action: action
        ))
    }
}
