import Foundation
import SessionKit

/// What the app adds to the Library when a listener pastes their own feed to recover the episode
/// a shared Margin belongs to (#454). It is the same entry Following builds for an episode, so the
/// episode goes through the existing source-import path, and it holds nothing of the feed link
/// itself: only the episode's own page and audio links, which the listener's feed gave.
public enum SharedEpisodeFeedEntry {
    /// The followed-source id these entries carry. No subscription is saved under it.
    public static let subscriptionId = "shared-episode-recovery"

    /// The entry for `item`, or nil when the feed gives it no audio to listen to.
    public static func entry(for item: ParsedFeedItem) -> FeedEntry? {
        let audio = nonEmpty(item.audioURL)
        guard let address = audio ?? nonEmpty(item.url) else { return nil }
        let guid = nonEmpty(item.guid)
        return FeedEntry(
            id: stableID(for: guid ?? nonEmpty(item.id) ?? address),
            subscriptionId: subscriptionId,
            canonicalURL: nonEmpty(item.url) ?? address,
            audioURL: audio,
            title: item.title,
            author: nonEmpty(item.author),
            summary: item.summary,
            publishedAt: item.publishedAt,
            state: .imported,
            audioDurationMs: item.durationMs,
            episodeGUID: guid
        )
    }

    /// The entry id ends up in diagnostics keys, and a GUID can be a private link, so the entry is
    /// named by a hash of it (FNV-1a, stable across launches) rather than by the GUID itself.
    static func stableID(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "episode-" + String(hash, radix: 16)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
