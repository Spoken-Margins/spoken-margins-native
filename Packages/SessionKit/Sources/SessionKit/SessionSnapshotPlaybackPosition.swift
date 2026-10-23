import Foundation

/// The part of a `SessionSnapshot` that moves with every playback progress tick (#2074).
///
/// The app ticks twice a second while audio plays, and each tick used to publish a whole new snapshot to every
/// screen. The fields here change on almost every tick; the rest of the snapshot changes when something happens
/// (status, target, chapter, a whole percent). The app publishes the position to the few views that follow it and
/// publishes the snapshot to everyone else only when something other than the position moved.
public struct PlaybackTickPosition: Equatable, Sendable {
    public var mediaTimeMs: Int?
    public var textStart: Int?
    public var textEnd: Int?
    public var transcriptSegmentId: String?

    public init(mediaTimeMs: Int? = nil, textStart: Int? = nil, textEnd: Int? = nil, transcriptSegmentId: String? = nil) {
        self.mediaTimeMs = mediaTimeMs
        self.textStart = textStart
        self.textEnd = textEnd
        self.transcriptSegmentId = transcriptSegmentId
    }
}

extension SessionSnapshot {
    public var tickPosition: PlaybackTickPosition {
        PlaybackTickPosition(
            mediaTimeMs: currentMediaTimeMs, textStart: currentTextStart,
            textEnd: currentTextEnd, transcriptSegmentId: currentTranscriptSegmentId
        )
    }

    /// True when `other` is this snapshot with only its playback position different, or not different at all.
    /// Whole-percent progress, status, chapter and every other field must match.
    public func equalIgnoringPlaybackPosition(to other: SessionSnapshot) -> Bool {
        var aligned = other
        aligned.currentMediaTimeMs = currentMediaTimeMs
        aligned.currentTextStart = currentTextStart
        aligned.currentTextEnd = currentTextEnd
        aligned.currentTranscriptSegmentId = currentTranscriptSegmentId
        return aligned == self
    }
}

/// A yes/no fact about the open item that costs a store read to learn, read once per item until told to forget it.
/// The Item screen asks "is this a remote stream?" in `body`; the answer only changes when the item does.
public final class CachedItemFlag {
    private var cached: (itemID: String, value: Bool)?

    public init() {}

    /// The remembered answer for `itemID`, or `load()`'s, remembered.
    public func value(itemID: String, load: () -> Bool) -> Bool {
        if let cached, cached.itemID == itemID { return cached.value }
        let value = load()
        cached = (itemID, value)
        return value
    }

    /// Forget the answer, for when the open item is replaced or its stored media may have changed.
    public func invalidate() { cached = nil }
}
