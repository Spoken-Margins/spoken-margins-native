import Foundation
import SessionKit

/// The Library item that already is a recovered shared episode (#454), and whether finding it filled in the identity
/// the item was added without.
public struct ExistingRecoveredEpisode: Equatable, Sendable {
    public let itemId: String
    public let identityChanged: Bool
}

extension SQLiteSessionStore {
    /// Finds the Library item that already is `entry`'s episode and that `accepts` (the pending packet's own rule),
    /// and fills in the episode identity it was added without (GUID, show, publish day, length) (#2506, fix class
    /// `summary-read` and `async-store`). It runs on one background read: the summaries name the candidates, only
    /// those items are read whole (for the GUID and the packet's rule), and the one that is found is saved from the
    /// copy already read. Before, the main thread listed the summaries, read each candidate, read the found item a
    /// second time to save it, and then rebuilt the whole Library list.
    ///
    /// The audio link names the episode. A GUID alone does not (some feeds reuse short ones, and many give every
    /// episode the show's page as its link), so it needs the title beside it.
    public func findRecoveredEpisode(
        for entry: FeedEntry, showTitle: String?, accepts: (Item) -> Bool
    ) throws -> ExistingRecoveredEpisode? {
        let audioURL = entry.audioURL
        let guid = entry.episodeGUID
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidateIDs = entry.recoveryCandidateItemIDs(among: try listItemSummaries())
        for id in candidateIDs {
            guard let item = try? loadItem(id: id) else { continue }
            let sameEpisode: Bool
            if let audioURL, item.media?.url == audioURL {
                sameEpisode = true
            } else if let guid, item.episodeGUID?.trimmingCharacters(in: .whitespacesAndNewlines) == guid {
                sameEpisode = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title
            } else {
                sameEpisode = false
            }
            guard sameEpisode, accepts(item) else { continue }
            return ExistingRecoveredEpisode(
                itemId: id, identityChanged: try completeEpisodeIdentity(of: item, entry: entry, showTitle: showTitle))
        }
        return nil
    }

    /// Saves the identity the item `itemId` was added without. Returns whether the item changed.
    @discardableResult
    public func completeEpisodeIdentity(itemId: String, entry: FeedEntry, showTitle: String?) throws -> Bool {
        try completeEpisodeIdentity(of: try loadItem(id: itemId), entry: entry, showTitle: showTitle)
    }

    private func completeEpisodeIdentity(of before: Item, entry: FeedEntry, showTitle: String?) throws -> Bool {
        var item = before
        entry.fillEpisodeIdentity(of: &item, showTitle: showTitle)
        if item.sourceTitle == nil { item.sourceTitle = item.showTitle }
        if item.media?.durationMs == nil, let feedDuration = entry.audioDurationMs { item.media?.durationMs = feedDuration }
        guard item != before else { return false }
        try saveItem(item)
        return true
    }
}
