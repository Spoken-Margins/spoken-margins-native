import Foundation

extension PlaybackNowMargins.Margin {
    /// Use the whole item's collection, including prior sessions. Response Margins have another clock.
    public init?(own interjection: Interjection, itemID: String) {
        guard interjection.itemId == itemID, interjection.status == "active", interjection.targetType == .item,
              let time = interjection.anchor.mediaTimeMs, time >= 0 else { return nil }
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
