import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// The stretch of the item's stored source transcript around a media time, or nil when the item has no stored
    /// transcript or nothing was said near that time (#2506).
    ///
    /// A mapped episode's timeline is several MB of JSON, so a caller on the main actor reads this through
    /// `StoreReader` instead of loading the timeline itself and cutting the window out on the main thread.
    public func storedSourceContextWindow(
        itemId: String,
        anchorMediaTimeMs: Int,
        windowBeforeMs: Int,
        windowAfterMs: Int
    ) throws -> TranscriptTimeline? {
        guard let timeline = try loadTranscriptTimeline(itemId: itemId)?.timeline else { return nil }
        return SourceAnchorContextResolver.sourceContextWindow(
            from: timeline, anchorMediaTimeMs: anchorMediaTimeMs,
            windowBeforeMs: windowBeforeMs, windowAfterMs: windowAfterMs)
    }
}
