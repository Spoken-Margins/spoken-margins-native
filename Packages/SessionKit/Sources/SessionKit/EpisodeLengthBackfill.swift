import Foundation

/// Which Library episodes already have a feed entry that states their length (#4186). Pure, so the app reads the
/// summaries and the stored feed entries off the main actor, asks this, and writes the answer back in one read.
///
/// Only a missing length is ever filled. The match is the first rule `RecoveredEpisodeLookup` uses: the item's audio
/// link equals the entry's audio link, exactly. A summary carries no GUID, so there is no GUID match here.
public enum EpisodeLengthBackfill {
    /// An item that is recorded audio with no length yet, and so could be filled.
    public static func isCandidate(_ item: any LibraryItemFields) -> Bool {
        guard let media = item.media, media.sourceType == .nativeMediaFile || media.sourceType == .remoteStream else { return false }
        return PlayableLength.ms(media: media) == nil
    }

    /// The length each candidate gets from the entry that names its audio file, in the items' order.
    /// - Parameter excludingItemId: the engine's current item. Its length is written by the player, and the engine
    ///   caches the item, so a store write beside it could be saved over.
    public static func statedFills(
        items: [any LibraryItemFields], entries: [FeedEntry], excludingItemId: String?
    ) -> [(itemId: String, durationMs: Int)] {
        var lengthByAudioURL: [String: Int] = [:]
        for entry in entries {
            guard let audioURL = entry.audioURL, let stated = entry.audioDurationMs, stated > 0,
                  lengthByAudioURL[audioURL] == nil else { continue }
            lengthByAudioURL[audioURL] = stated
        }
        guard !lengthByAudioURL.isEmpty else { return [] }
        var fills: [(itemId: String, durationMs: Int)] = []
        for item in items where item.id != excludingItemId && item.deletedAt == nil && isCandidate(item) {
            guard let url = item.media?.url, let stated = lengthByAudioURL[url] else { continue }
            fills.append((item.id, stated))
        }
        return fills
    }
}
