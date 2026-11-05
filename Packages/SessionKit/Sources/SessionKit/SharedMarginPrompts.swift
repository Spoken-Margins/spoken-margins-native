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

    public var senderLabel: String { SharedPacketArrival.snapshotSenderLabel(layer.displayLabel) }
}

public enum SharedMarginPrompts {
    public static func isLayerPlaybackEligible(
        _ layer: ImportedCommentaryLayer,
        records: [ImportedCommentaryInterjection]
    ) -> Bool {
        guard layer.deletedAt == nil,
              layer.isEnabled,
              layer.sourceResolutionStatus != .wrongSource else { return false }
        return records.contains { isPlayable($0, in: layer) }
    }

    public static func position(
        _ interjection: ImportedCommentaryInterjection,
        in layer: ImportedCommentaryLayer? = nil
    ) -> Int {
        mediaTimeMs(interjection, in: layer)
            ?? interjection.resolution.localStartChar
            ?? .max
    }

    public static func isPlayable(_ resolution: ImportedAnchorResolution) -> Bool {
        SharedMarginPlacementStatus.isPlaced(resolution)
    }

    /// Placed, or still waiting for the episode's placement pass with a time from the sender. A friend who presses
    /// play before the episode has downloaded hears each Margin at the sender's time instead of not at all (#3059).
    public static func isPlayable(_ interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> Bool {
        isPlayable(interjection.resolution) || senderTimeAwaitingPlacement(interjection, in: layer) != nil
    }

    /// Where the Margin plays in the episode: its placement in the listener's copy, else the sender's time while
    /// the layer still waits for its pass. Once a pass has run, a Margin it couldn't find or found twice stays
    /// silent rather than playing at a guessed time.
    public static func mediaTimeMs(_ interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer?) -> Int? {
        if let local = interjection.resolution.localMediaTimeMs { return local }
        guard let layer else { return nil }
        return senderTimeAwaitingPlacement(interjection, in: layer)
    }

    private static func senderTimeAwaitingPlacement(
        _ interjection: ImportedCommentaryInterjection,
        in layer: ImportedCommentaryLayer
    ) -> Int? {
        let resolution = interjection.resolution
        guard layer.awaitsPlacementPass, resolution.localMediaTimeMs == nil, !resolution.isAmbiguous,
              resolution.evidenceClass != .ambiguous, resolution.evidenceClass != .absentFromRecipientEdition,
              let sender = interjection.anchorEvidence.mediaTimeMs, sender >= 0 else { return nil }
        return sender
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
                    .filter { isPlayable($0, in: layer) }
                    .sorted { lhs, rhs in
                        position(lhs, in: layer) < position(rhs, in: layer)
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
            if let anchor = mediaTimeMs(prompt.interjection, in: prompt.layer),
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
            position($0.interjection, in: $0.layer)
                < position($1.interjection, in: $1.layer)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
