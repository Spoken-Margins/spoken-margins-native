import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitSharing

/// The Library side of recovering a shared Margin's episode from a feed the listener pasted (#454).
/// Neither method touches the pasted link: they only see the episode's own entry and the show's title.
extension Gate1AppModel {
    /// The Library item that already is `entry`'s episode, if there is one, with the episode identity
    /// it was added without (GUID, show, publish day) filled in so the pending packet can find it.
    func libraryItemID(forRecoveredEpisode entry: FeedEntry, showTitle: String?) throws -> String? {
        let store = try requireStore()
        let items = try store.listItems()
        let episode = SharedItemIdentity(
            itemType: .podcast,
            canonicalURL: entry.canonicalURL,
            originalURL: entry.canonicalURL,
            title: entry.title,
            showTitle: showTitle,
            episodeGUID: entry.episodeGUID,
            enclosureURL: entry.audioURL,
            publishedAt: entry.publishedAt.map { ISO8601DateFormatter().string(from: $0) },
            durationMs: entry.audioDurationMs
        )
        let audioURL = entry.audioURL
        guard let itemId = SharedPacketItemMatcher.matchingItemId(for: episode, among: items)
            ?? items.first(where: { audioURL != nil && $0.media?.url == audioURL })?.id else { return nil }
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
