import Foundation
import SessionKit

/// Whether a pending packet will accept the episode a listener recovers from their own feed (#454).
/// The feed matcher finds candidates by title, day and length; the import then decides by
/// `ImportedItemResolver.canRepresentSameWork`, which also wants the show or the day to back the
/// title. Recovery asks the import's own rule first, so it never adds or reuses an episode the
/// pending import would then refuse.
public enum RecoveredEpisodeMatch {
    /// The identity a Library item has once recovery fills it from `entry`. `existing` is an item
    /// already in the Library; without one, it is the item recovery adds: a streamed episode with the
    /// feed's title, the entry's links and length, and the show's title.
    public static func identity(of entry: FeedEntry, showTitle: String?, existing: Item? = nil) -> SharedItemIdentity {
        var item = existing ?? Item(
            id: entry.id, title: entry.title, mediaType: "transcript_backed_media", text: nil,
            externalReference: entry.canonicalURL, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: entry.audioURL, durationMs: entry.audioDurationMs)
        )
        entry.fillEpisodeIdentity(of: &item, showTitle: showTitle)
        if item.media != nil, item.media?.durationMs == nil { item.media?.durationMs = entry.audioDurationMs }
        return SharedItemIdentityBuilder.localIdentity(for: item)
    }

    /// True when the pending packet's item `shared` would find `entry`'s episode once recovery adds it,
    /// or once it fills in `existing`.
    public static func accepts(_ shared: SharedItemIdentity, entry: FeedEntry, showTitle: String?, existing: Item? = nil) -> Bool {
        ImportedItemResolver.canRepresentSameWork(shared, identity(of: entry, showTitle: showTitle, existing: existing))
    }
}
