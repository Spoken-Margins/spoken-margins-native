import Foundation

/// The publisher's own recording of an article, such as a Substack voiceover (#545, slice 1 of
/// #239). It is kept beside the item as its own record kind, never inside `Item`, so the item
/// stays a plain article: Build 29 never reads this kind, packets never carry it, and deleting
/// the item removes it.
public struct PublisherAudio: Codable, Equatable, Sendable {
    public var itemId: String
    public var audioURL: String
    public var durationMs: Int?
    /// Where the recording was found, e.g. `feed_enclosure` for a followed feed entry's enclosure.
    public var detectedFrom: String
    /// The recording's text-to-time map (#546): article sentences with their times in the
    /// recording. Kept here rather than as a `source_transcript_timeline` record, so Build 29
    /// never treats the article as transcript-backed. Nil until made, or when making it failed.
    public var textMap: TranscriptTimeline?
    /// Why the map exists or doesn't, e.g. `aligned(47 of 50 sentences)` or `no_match(…)`.
    /// Nil until the app has tried once.
    public var textMapStatus: String?

    public init(itemId: String, audioURL: String, durationMs: Int? = nil, detectedFrom: String, textMap: TranscriptTimeline? = nil, textMapStatus: String? = nil) {
        self.itemId = itemId
        self.audioURL = audioURL
        self.durationMs = durationMs
        self.detectedFrom = detectedFrom
        self.textMap = textMap
        self.textMapStatus = textMapStatus
    }

    /// The record after one try at making its map: the map is kept only when the alignment
    /// placed enough of the article (`PublisherAudioAligner.minimumPlacedFraction`).
    public func recordingTextMap(_ alignment: PublisherAudioAlignment) -> PublisherAudio {
        var updated = self
        updated.textMap = alignment.timeline
        updated.textMapStatus = alignment.status
        return updated
    }

    /// The record to save when the same article is imported again, e.g. from a second feed that
    /// carries the same post: an existing record for the same recording keeps its map and status,
    /// so the map isn't thrown away and the recording isn't transcribed again. A different
    /// recording starts over.
    public func keepingTextMap(of existing: PublisherAudio?) -> PublisherAudio {
        guard let existing, isSameRecording(as: existing) else { return self }
        var updated = self
        updated.textMap = existing.textMap
        updated.textMapStatus = existing.textMapStatus
        return updated
    }

    /// Whether `other` is this item's record for the same recording. A map made from one
    /// recording must not be saved over a record that now points at another.
    public func isSameRecording(as other: PublisherAudio?) -> Bool {
        guard let other else { return false }
        return other.itemId == itemId && other.audioURL == audioURL
    }

    /// The record after a try that never reached alignment, such as a failed download.
    public func recordingTextMapFailure(_ reason: String) -> PublisherAudio {
        var updated = self
        updated.textMap = nil
        updated.textMapStatus = reason
        return updated
    }
}

/// Stores that don't adopt this simply remember no publisher audio.
public protocol PublisherAudioRepository {
    func savePublisherAudio(_ audio: PublisherAudio) throws
    func loadPublisherAudio(itemId: String) throws -> PublisherAudio?
}
