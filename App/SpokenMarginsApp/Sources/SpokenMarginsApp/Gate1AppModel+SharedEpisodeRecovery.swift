import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitSharing

/// The Library side of recovering a shared Margin's episode from a feed the listener pasted (#454).
/// Neither method touches the pasted link: they only see the episode's own entry and the show's title.
extension Gate1AppModel {
    /// The Library item that already is `entry`'s episode, if there is one that the pending packet's
    /// item `shared` will accept, with the episode identity it was added without (GUID, show, publish
    /// day) filled in so the pending packet can find it. An item the packet would still refuse (one
    /// added by its audio link and titled from the file name, say) is left alone, and recovery adds
    /// the feed's episode beside it instead.
    func libraryItemID(forRecoveredEpisode entry: FeedEntry, showTitle: String?, acceptedBy shared: SharedItemIdentity) throws -> String? {
        let store = try requireStore()
        let audioURL = entry.audioURL
        let guid = entry.episodeGUID
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The audio link names the episode. A GUID alone does not (some feeds reuse short ones, and
        // many give every episode the show's page as its link), so it needs the title beside it.
        // Summaries name the candidates; only those items are read whole, for the GUID and the packet's rule (#2506).
        let candidateIDs = entry.recoveryCandidateItemIDs(among: try store.listItemSummaries())
        guard let itemId = try candidateIDs.lazy.compactMap({ try? store.loadItem(id: $0) }).first(where: { item in
            let sameEpisode: Bool
            if let audioURL, item.media?.url == audioURL {
                sameEpisode = true
            } else if let guid, item.episodeGUID?.trimmingCharacters(in: .whitespacesAndNewlines) == guid {
                sameEpisode = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title
            } else {
                sameEpisode = false
            }
            return sameEpisode && RecoveredEpisodeMatch.accepts(shared, entry: entry, showTitle: showTitle, existing: item)
        })?.id else { return nil }
        try completeEpisodeIdentity(itemId: itemId, entry: entry, showTitle: showTitle)
        return itemId
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
        try completeEpisodeIdentity(itemId: itemId, entry: entry, showTitle: showTitle)
        diagnostics["lastSharedEpisodeRecovery"] = "added:\(itemId)"
        return itemId
    }

    private func completeEpisodeIdentity(itemId: String, entry: FeedEntry, showTitle: String?) throws {
        let store = try requireStore()
        var item = try store.loadItem(id: itemId)
        let before = item
        entry.fillEpisodeIdentity(of: &item, showTitle: showTitle)
        if item.sourceTitle == nil { item.sourceTitle = item.showTitle }
        if item.media?.durationMs == nil, let feedDuration = entry.audioDurationMs { item.media?.durationMs = feedDuration }
        guard item != before else { return }
        try store.saveItem(item)
        libraryItems = try loadLibraryRows(store: store)
    }
}
