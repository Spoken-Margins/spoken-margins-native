import Foundation

extension PlaybackNowMargins.Margin {
    /// Use the whole item's collection, including prior sessions. Response Margins have another clock.
    /// `clock` is the map onto the playing file's clock when that is a spoken note's Shorter pauses version (#5288), read
    /// off the main thread; nil when the recording, or anything else, plays. Saved times are on the recording's clock
    /// (#4779), and the position is compared with the playhead, so it is moved onto the file playing.
    public init?(own interjection: Interjection, itemID: String, clock: SpokenNoteCleanMap? = nil) {
        guard interjection.itemId == itemID, interjection.status == "active", interjection.targetType == .item,
              interjection.hasPlace, let saved = interjection.anchor.mediaTimeMs, saved >= 0 else { return nil }
        let time = clock?.cleanMs(fromRecordedMs: saved) ?? saved
        self.init(id: "\(interjection.sessionId)::\(interjection.id)", position: Double(time) / 1_000, origin: .own)
    }

    /// Share the moment player's position rules, including its approximate sender-time fallback.
    public init?(shared interjection: ImportedCommentaryInterjection, layer: ImportedCommentaryLayer, itemID: String) {
        guard layer.itemId == itemID, layer.deletedAt == nil, interjection.layerId == layer.id,
              let position = SharedMarginPlaybackPosition(interjection) else { return nil }
        self.init(id: "shared::\(layer.id)::\(interjection.id)", position: Double(position.mediaTimeMs) / 1_000,
                  origin: .shared, isApproximate: position.isApproximate)
    }
}
