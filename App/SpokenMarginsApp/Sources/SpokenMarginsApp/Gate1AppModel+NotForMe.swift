import Foundation
import SessionKit

/// The one Not for me store (#4285 PR 6). It lives beside the database (`Application Support/not-for-me.json` in
/// the app; a test's own folder when the test moves the database), and what to record and how to match lives in
/// SessionKit (`NotForMeStore`, `FollowedSourceCoordinator`); the model only wires it.
@MainActor
final class NotForMeHolder {
    /// Exists before the store, so the followed-source coordinator can be handed its provider at once.
    let box = NotForMeSnapshotBox()
    private var store: NotForMeStore?
    /// The drawer's catalog, for the entry id a hide records and the reconcile (#4285). Set by the app once the drawer
    /// exists; nil in tests that have no drawer, and then hides match by feed key and recorded follows alone.
    var catalog: (@MainActor () -> SourceCatalog?)?

    func store(directory: URL) -> NotForMeStore {
        if let store { return store }
        let created = NotForMeStore(fileURL: directory.appending(path: NotForMeStore.fileName), box: box)
        store = created
        return created
    }
}

extension Gate1AppModel {
    /// What the drawer and the coordinator read without awaiting the store. Empty until the first load.
    var notForMeSnapshot: NotForMeSnapshot { notForMe.box.current }

    /// The coordinator's `suppressedEntry` provider, backed by the store's box.
    var notForMeSuppressedEntry: @Sendable (_ feedKey: String, _ entryKey: String) -> Bool {
        notForMe.box.suppressedEntry
    }

    func requireNotForMeStore() throws -> NotForMeStore {
        try notForMe.store(directory: databaseURL().deletingLastPathComponent())
    }

    /// Read the marks before a followed-source refresh saves entries, so a launch refresh can't revive a marked
    /// episode. The store reads its file once; later calls return at once.
    func loadNotForMe() async {
        guard let store = try? requireNotForMeStore() else { return }
        await store.load()
    }

    /// Writes the mark for a followed show's episode. Returns whether it was written, so Undo knows whether to take
    /// one off. An episode with nothing to recognise it by, or a feed with no host, is dismissed without a mark.
    func markNotForMe(_ entry: FeedEntry) async -> Bool {
        guard let subscription = feedSubscriptions.first(where: { $0.id == entry.subscriptionId }),
              let store = try? requireNotForMeStore() else { return false }
        do {
            try await store.markItem(entry, of: subscription)
            return true
        } catch {
            diagnostics["notForMeMark"] = Self.notForMeFailure(error)
            return false
        }
    }

    func unmarkNotForMe(_ entry: FeedEntry) async {
        guard let subscription = feedSubscriptions.first(where: { $0.id == entry.subscriptionId }),
              let store = try? requireNotForMeStore() else { return }
        do {
            try await store.unmarkItem(entry, of: subscription)
        } catch {
            diagnostics["notForMeUnmark"] = Self.notForMeFailure(error)
        }
    }

    /// The store's own reasons by name; anything else by its type only, so no file path reaches Diagnostics.
    static func notForMeFailure(_ error: Error) -> String {
        if let storeError = error as? NotForMeStore.StoreError {
            switch storeError {
            case .unusableFeedURL: return "failed:unusableFeedURL"
            case .unidentifiableItem: return "failed:unidentifiableItem"
            case .fileNotReadable: return "failed:fileNotReadable"
            }
        }
        return "failed:\(String(describing: type(of: error)))"
    }
}

// MARK: Not for me on a source (#4285 PR 7)

extension Gate1AppModel {
    /// The catalog entries the drawer followed, by entry id → source id. Read for the hide reconcile and for the entry
    /// id a hide records.
    private var drawerRecordedSourceIds: [String: String] {
        UserDefaults.standard.dictionary(forKey: CatalogDrawerModel.followedSourcesKey) as? [String: String] ?? [:]
    }

    /// A followed source is never hidden: each time the subscriptions are published, any hide that matches one goes.
    /// So following it again in any way (the drawer, search, OPML, paste, Undo) clears the hide.
    func reconcileNotForMeHides(with subscriptions: [FeedSubscription]) async {
        guard let store = try? requireNotForMeStore() else { return }
        let followed = NotForMeHideReconcile.followed(
            subscriptions: subscriptions, catalog: notForMe.catalog?(), recordedSourceIds: drawerRecordedSourceIds)
        do {
            try await store.removeHides(followedFeedKeys: followed.feedKeys, followedEntryIds: followed.entryIds)
        } catch {
            diagnostics["notForMeReconcile"] = Self.notForMeFailure(error)
        }
    }

    /// Hides a source from every pack, Top and the subject chips on this iPhone. The caller unfollows first.
    func hideNotForMeSource(feedURL: String, title: String, artworkURL: String?, sourceId: String?) async {
        guard let store = try? requireNotForMeStore() else { return }
        let entryId = NotForMeHideReconcile.catalogEntryId(
            forFeedURL: feedURL, sourceId: sourceId, catalog: notForMe.catalog?(), recordedSourceIds: drawerRecordedSourceIds)
        do {
            try await store.hideSource(catalogEntryId: entryId, feedURL: feedURL, title: title, artworkURL: artworkURL)
        } catch {
            diagnostics["notForMeHide"] = Self.notForMeFailure(error)
        }
    }

    /// "Show again", or the Undo of a hide. It doesn't follow the source.
    func showNotForMeSourceAgain(feedURL: String) async {
        guard let store = try? requireNotForMeStore() else { return }
        do {
            try await store.showAgain(feedURL: feedURL)
        } catch {
            diagnostics["notForMeShowAgain"] = Self.notForMeFailure(error)
        }
    }

    func notForMeHiddenSources() async -> [NotForMeStore.HiddenSource] {
        guard let store = try? requireNotForMeStore() else { return [] }
        await store.load()
        return await store.hiddenSources()
    }

    /// Not for me on the Show screen: first it unfollows, as Unfollow does, then it writes the hide, so the hide is
    /// never dropped by the reconcile of a list that still holds the show. Undo takes the hide off, then follows the
    /// feed again, as Unfollow's Undo does.
    func notForMeShow(_ subscription: FeedSubscription) {
        let title = subscription.source.title ?? subscription.source.host
        let feedURL = subscription.source.canonicalURL
        let sourceId = subscription.source.id
        let artwork = notForMe.catalog?()?.entry(matchingFeedURL: feedURL)?.artworkURL
        unfollowShow(
            subscription,
            message: CatalogPackWords.hiddenMessage(title: title),
            undoAccessibilityLabel: CatalogPackWords.showUndoAccessibilityLabel(showTitle: title),
            onUndo: { [weak self] in await self?.showNotForMeSourceAgain(feedURL: feedURL) },
            afterUnfollow: { [weak self] in
                await self?.hideNotForMeSource(feedURL: feedURL, title: title, artworkURL: artwork, sourceId: sourceId)
            }
        )
    }
}

extension Gate1AppModel {
    /// Unfollow from a Pack screen row (#4285): the subscription whose feed matches the entry's goes, with its follow
    /// lists, and the list is published before this returns, so a hide written next is never undone by the
    /// reconcile. False when no subscription matches or the unfollow failed.
    func unfollowCatalogFeed(_ feedURL: String) async -> Bool {
        guard let key = SourceCatalog.feedKey(feedURL),
              let subscription = feedSubscriptions.first(where: { SourceCatalog.feedKey($0.source.canonicalURL) == key }),
              let coordinator = followedSourceCoordinator else { return false }
        let member = FollowListEditing.member(for: subscription)
        do {
            try await coordinator.unfollow(subscriptionId: subscription.id)
        } catch {
            return false
        }
        await removeFromFollowLists(member)
        await publishFeedSubscriptionsAfterChange()
        return true
    }
}
