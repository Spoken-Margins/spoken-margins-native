import Foundation

/// "Review new Margins" (#474): which of an item's shared Margins the listener hasn't heard, in the order they
/// play, and how the app words the offer to hear them.
///
/// A Margin is new until its voice first plays (#469, `SharedMarginHearing`). Only Margins the automatic
/// prompts would play are offered: an enabled layer that isn't the wrong source, and a Margin that is placed
/// at a time in this copy of the episode and has a voice to play. `MarginMomentSequence(reviewing:)` plays them.
public enum SharedMarginReview {
    /// One new shared Margin, with what the app needs to play it and mark it heard.
    public struct Entry: Sendable, Equatable {
        public let layer: ImportedCommentaryLayer
        public let interjection: ImportedCommentaryInterjection
        public let mediaTimeMs: Int
        /// Placed by a clock time or a map rather than a match, so the position is a best guess.
        public let isApproximate: Bool

        /// The identity the playback screen, the conductor and the Timeline all use for this Margin.
        public var marginId: String { SharedMarginReview.marginId(layerId: layer.id, interjectionId: interjection.id) }
        public var senderLabel: String { SharedMarginReview.senderLabel(of: layer) }
        public var anchor: MarginMomentAnchor {
            MarginMomentAnchor(marginId: marginId, mediaTimeMs: mediaTimeMs, label: senderLabel, isApproximate: isApproximate)
        }
    }

    /// The same text `SharedMarginRow.id` builds, so the playback screen can find the row for a Margin.
    public static func marginId(layerId: String, interjectionId: String) -> String {
        "shared::\(layerId)::\(interjectionId)"
    }

    public static func senderLabel(of layer: ImportedCommentaryLayer) -> String {
        let label = layer.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "Imported collection" : label
    }

    /// The item's new shared Margins in playing order: by place in the episode, then, where two share a place,
    /// by sender label and then by when it was made, so the same Margins always play the same way round.
    public static func entries(
        layers: [ImportedCommentaryLayer],
        records: [String: [ImportedCommentaryInterjection]]
    ) -> [Entry] {
        layers.flatMap { layer -> [Entry] in
            let layerRecords = records[layer.id] ?? []
            guard SharedMarginPrompts.isLayerPlaybackEligible(layer, records: layerRecords) else { return [] }
            return layerRecords.compactMap { record -> Entry? in
                guard record.isNewToListener, record.audioPath != nil,
                      SharedMarginPrompts.isPlayable(record.resolution),
                      let mediaTimeMs = record.resolution.localMediaTimeMs, mediaTimeMs >= 0 else { return nil }
                return Entry(
                    layer: layer, interjection: record, mediaTimeMs: mediaTimeMs,
                    isApproximate: record.resolution.evidenceClass == .mapInterpolated
                        || record.resolution.evidenceClass == .timestampFallback
                )
            }
        }.sorted(by: playsBefore)
    }

    /// The same, read from the repository for an item that isn't open.
    public static func entries(itemId: String, in repository: some ListeningSessionRepository) throws -> [Entry] {
        let layers = try repository.loadImportedCommentaryLayers(itemId: itemId)
        var records: [String: [ImportedCommentaryInterjection]] = [:]
        for layer in layers { records[layer.id] = try repository.loadImportedCommentaryInterjections(layerId: layer.id) }
        return entries(layers: layers, records: records)
    }

    /// The text of the offer shown before Continue: how many Margins and whose.
    public static func offerMessage(for entries: [Entry]) -> String {
        var senders: [String] = []
        for entry in entries where !senders.contains(entry.senderLabel) { senders.append(entry.senderLabel) }
        let count = entries.count
        let whose: String
        switch senders.count {
        case 0, 1: whose = senders.first ?? "a friend"
        case 2: whose = "\(senders[0]) and \(senders[1])"
        case 3: whose = "\(senders[0]), \(senders[1]) and \(senders[2])"
        default: whose = "\(senders[0]), \(senders[1]) and \(senders.count - 2) others"
        }
        return "\(count) new Margin\(count == 1 ? "" : "s") from \(whose). Hear \(count == 1 ? "it" : "them") in place first, then carry on from where you were."
    }

    private static func playsBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.mediaTimeMs != rhs.mediaTimeMs { return lhs.mediaTimeMs < rhs.mediaTimeMs }
        let (left, right) = (lhs.senderLabel, rhs.senderLabel)
        if left.lowercased() != right.lowercased() { return left.lowercased() < right.lowercased() }
        if left != right { return left < right }
        if lhs.interjection.createdAt != rhs.interjection.createdAt { return lhs.interjection.createdAt < rhs.interjection.createdAt }
        return lhs.marginId < rhs.marginId
    }
}

/// What the listener turned down on the new-Margins offer ("Listen without them", #474). The offer stays quiet for
/// that item until a Margin arrives that it hadn't asked about, so Continue on a two-hour episode with a friend's
/// Margin at minute 90 doesn't ask at every press. Hearing a Margin some other way never brings the offer back.
public struct NewMarginsOfferMemory: Sendable, Equatable {
    private var declined: [String: Set<String>] = [:]

    public init() {}

    /// The listener chose to carry on without hearing `margins` (their `marginId`s) on this item.
    public mutating func decline(itemId: String, margins: [String]) {
        declined[itemId, default: []].formUnion(margins)
    }

    /// Whether every one of `margins` has already been turned down on this item.
    public func isDeclined(itemId: String, margins: [String]) -> Bool {
        Set(margins).isSubset(of: declined[itemId] ?? [])
    }
}
