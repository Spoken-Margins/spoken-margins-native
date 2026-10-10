public struct ImportedCommentaryPrompt: Identifiable {
    public var id: String { interjection.id }
    public let layer: ImportedCommentaryLayer
    public let interjection: ImportedCommentaryInterjection
    public let index: Int
    public let count: Int

    public init(layer: ImportedCommentaryLayer, interjection: ImportedCommentaryInterjection, index: Int, count: Int) {
        self.layer = layer
        self.interjection = interjection
        self.index = index
        self.count = count
    }

    public var senderLabel: String { layer.displayLabel?.nilIfEmpty ?? "Unsigned sender" }
}

public enum SharedMarginPrompts {
    public static func isLayerPlaybackEligible(
        _ layer: ImportedCommentaryLayer,
        records: [ImportedCommentaryInterjection]
    ) -> Bool {
        guard layer.deletedAt == nil,
              layer.isEnabled,
              layer.sourceResolutionStatus != .wrongSource else { return false }
        return records.contains { isPlayable($0.resolution) }
    }

    public static func position(
        _ interjection: ImportedCommentaryInterjection
    ) -> Int {
        interjection.resolution.localMediaTimeMs
            ?? interjection.resolution.localStartChar
            ?? .max
    }

    public static func isPlayable(_ resolution: ImportedAnchorResolution) -> Bool {
        SharedMarginPlacementStatus.isPlaced(resolution)
    }

    public static func prompts(
        layers: [ImportedCommentaryLayer],
        recordsByLayerID: [String: [ImportedCommentaryInterjection]],
        announcedIDs: Set<String>,
        includeAnnounced: Bool
    ) -> [ImportedCommentaryPrompt] {
        layers
            .filter { layer in
                isLayerPlaybackEligible(
                    layer,
                    records: recordsByLayerID[layer.id] ?? []
                )
            }
            .flatMap { layer in
                let records = (recordsByLayerID[layer.id] ?? [])
                    .filter { isPlayable($0.resolution) }
                    .sorted { lhs, rhs in
                        position(lhs) < position(rhs)
                    }
                return records.enumerated().compactMap { pair -> ImportedCommentaryPrompt? in
                    let (offset, record) = pair
                    guard includeAnnounced || !announcedIDs.contains(record.id) else {
                        return nil
                    }
                    return ImportedCommentaryPrompt(
                        layer: layer,
                        interjection: record,
                        index: offset + 1,
                        count: records.count
                    )
                }
            }
    }

    public static func crossed(
        prompts: [ImportedCommentaryPrompt],
        previous: SessionSnapshot,
        current: SessionSnapshot
    ) -> [ImportedCommentaryPrompt] {
        prompts.filter { prompt in
            if let anchor = prompt.interjection.resolution.localMediaTimeMs,
               previous.currentMediaTimeMs != nil, current.currentMediaTimeMs != nil {
                return PlaybackAnchorCrossing.isCrossed(
                    anchor: anchor, before: previous.currentMediaTimeMs, after: current.currentMediaTimeMs
                )
            }
            if let anchor = prompt.interjection.resolution.localStartChar {
                return PlaybackAnchorCrossing.isCrossed(
                    anchor: anchor, before: previous.currentTextStart, after: current.currentTextStart
                )
            }
            return false
        }.sorted {
            position($0.interjection)
                < position($1.interjection)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
