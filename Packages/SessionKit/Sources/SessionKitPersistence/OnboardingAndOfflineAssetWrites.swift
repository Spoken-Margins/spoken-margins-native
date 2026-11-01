import Foundation
import SessionKit

/// Two small multi-row writes that ran on the main actor, for a caller off it (#2509, fix class `write-behind`).
/// Callers run them through `StoreReader.read`.
public enum OnboardingAndOfflineAssetWrites {
    /// Saves a downloaded guided tour over the bundled one: the item (read as it is now, or `fallback` when the tour
    /// was never saved), its audio asset and its chapter timeline, in one transaction, so the tour is never left with
    /// the new audio and the old item. Returns the item as saved.
    public static func applyGuidedTour(
        itemId: String,
        fallback: Item,
        edit: (inout Item) -> Void,
        asset: AudioAsset,
        timeline: SourceTranscriptTimeline,
        in store: SQLiteSessionStore
    ) throws -> Item {
        try store.withSessionTransaction {
            var item = (try? store.loadItem(id: itemId)) ?? fallback
            edit(&item)
            try store.saveItem(item)
            try store.saveAudioAsset(asset)
            try store.saveTranscriptTimeline(timeline)
            return item
        }
    }

    /// Marks the item's owned offline assets of `category` redundant (their audio is now held in a better form), each in
    /// its own transaction, and returns how many it changed. An asset already marked is left alone.
    @discardableResult
    public static func markRedundant(
        category: OfflineAssetCategory, itemId: String, in store: SQLiteSessionStore
    ) throws -> Int {
        var changed = 0
        for asset in try store.loadOwnedOfflineAssets(itemId: itemId) where asset.category == category && !asset.isRedundant {
            if try store.updateOwnedOfflineAsset(id: asset.id, { $0.isRedundant = true }) != nil { changed += 1 }
        }
        return changed
    }
}
