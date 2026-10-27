import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// Saves a publisher recording that a shared link's lookup found, unless the listener removed the article while
    /// the page loaded (#810). A record already kept for the same recording keeps its text map and status.
    /// Returns the saved record, or nil when the item is gone. The item check, the read of the earlier record and
    /// the save run in the caller's order, so the app runs the whole step through `StoreReader`, off the main
    /// actor (#2507). The check reads the item's summary, not its text, which can be a whole book.
    public func savePublisherAudioIfItemExists(_ found: PublisherAudio) throws -> PublisherAudio? {
        // One transaction, so a text map the mapper saves meanwhile isn't overwritten by an older read, and a
        // deletion can't leave an orphan record between the check and the save.
        try withSessionTransaction {
            guard try loadItemSummary(id: found.itemId) != nil else { return nil }
            let audio = found.keepingTextMap(of: try loadPublisherAudio(itemId: found.itemId))
            try savePublisherAudio(audio)
            return audio
        }
    }
}
