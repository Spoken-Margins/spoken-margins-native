import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// Gives recorded audio the length it was added without (#4186): the downloaded file's own length, or the one a
    /// followed show's feed states. Only a missing length is filled (nil, 0 or negative). A length that is already
    /// there stays: only the player replaces it, on first play. Returns whether the item changed.
    ///
    /// Always call it inside `StoreReader(store).read { … }`, off the main actor, and never for the engine's current
    /// item: that item's length is written by the player's own write-back, and the engine caches the item, so a
    /// write beside it could be saved over.
    @discardableResult
    public func fillMissingMediaDuration(itemId: String, durationMs: Int) throws -> Bool {
        guard durationMs > 0 else { return false }
        var item = try loadItem(id: itemId)
        guard let media = item.media, media.sourceType == .nativeMediaFile || media.sourceType == .remoteStream,
              PlayableLength.ms(media: media) == nil else { return false }
        item.media?.durationMs = durationMs
        try saveItem(item)
        return true
    }
}
