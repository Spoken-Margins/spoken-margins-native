import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence
import SessionKitSharing

/// The Library side of recovering a shared Margin's episode from a feed the listener pasted (#454).
/// Neither method touches the pasted link: they only see the episode's own entry and the show's title.
extension Gate1AppModel {
    /// The Library item that already is `entry`'s episode, if there is one that the pending packet's
    /// item `shared` will accept, with the episode identity it was added without (GUID, show, publish
    /// day) filled in so the pending packet can find it. An item the packet would still refuse (one
    /// added by its audio link and titled from the file name, say) is left alone, and recovery adds
    /// the feed's episode beside it instead.
    func libraryItemID(forRecoveredEpisode entry: FeedEntry, showTitle: String?, acceptedBy shared: SharedItemIdentity) async throws -> String? {
        let store = try requireStore()
        // One background read finds the item (the summaries name the candidates, only those are read whole, for the
        // GUID and the packet's rule) and fills in its identity from the copy it read (#2506). The audio link names the
        // episode; a GUID alone does not, so it needs the title beside it.
        guard let found = try await StoreReader(store).read({ store in
            try store.findRecoveredEpisode(for: entry, showTitle: showTitle) { item in
                RecoveredEpisodeMatch.accepts(shared, entry: entry, showTitle: showTitle, existing: item)
            }
        }) else { return nil }
        if found.identityChanged {
            try await reloadLibraryRowsOffMain(store: store)
        }
        return found.itemId
    }

    /// Adds `entry`'s episode through the same path as a followed episode, without playing it and
    /// without saving the feed it came from.
    func addRecoveredSharedEpisode(_ entry: FeedEntry, showTitle: String?) async throws -> String {
        let handoff = SourceLinkHandoff(
            id: "shared-episode-\(UUID().uuidString)",
            inputURL: entry.audioURL ?? entry.canonicalURL,
            sourceSurface: "shared_margin_feed_recovery",
            startSession: false
        )
        guard let itemId = try await importSourceLinkInBackground(handoff, feedEntry: entry, subscription: nil) else {
            throw SessionKitError.persistenceFailed("shared_episode_not_playable")
        }
        let store = try requireStore()
        let identityChanged = try await StoreReader(store).read { try $0.completeEpisodeIdentity(itemId: itemId, entry: entry, showTitle: showTitle) }
        if identityChanged {
            try await reloadLibraryRowsOffMain(store: store) // the rows are on screen when this returns, as before (#2505)
        }
        diagnostics["lastSharedEpisodeRecovery"] = "added:\(itemId)"
        return itemId
    }
}
