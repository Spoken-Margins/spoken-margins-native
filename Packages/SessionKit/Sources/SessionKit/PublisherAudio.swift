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

    public init(itemId: String, audioURL: String, durationMs: Int? = nil, detectedFrom: String) {
        self.itemId = itemId
        self.audioURL = audioURL
        self.durationMs = durationMs
        self.detectedFrom = detectedFrom
    }
}

/// Stores that don't adopt this simply remember no publisher audio.
public protocol PublisherAudioRepository {
    func savePublisherAudio(_ audio: PublisherAudio) throws
    func loadPublisherAudio(itemId: String) throws -> PublisherAudio?
}
