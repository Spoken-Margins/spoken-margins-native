import Foundation

extension SharedMarginReview {
    /// The Margins a friend's episode that can't play can still offer (#3392). `entries` needs a placement in the
    /// listener's copy of the episode, and a podcast that never downloaded has none: its Margins import unplaced, with
    /// only the sender's time. `SharedMarginPrompts` already gives that time for a layer still awaiting its placement
    /// pass (#3059), so it is used here; a placed Margin keeps its placement. `entries` itself is unchanged for everyone
    /// else.
    ///
    /// `asking`: the listener asked to hear them (a Review tap on the dead episode), so every layer counts. Without it
    /// only layers set to play on their own (`.guided`) do: a Margin voice never starts by itself with auto-play off
    /// (`SharedMarginPromptStyle`).
    public static func entriesWithoutEpisode(
        layers: [ImportedCommentaryLayer],
        records: [String: [ImportedCommentaryInterjection]],
        ownMargins: [Interjection] = [],
        asking: Bool
    ) -> [Entry] {
        let contexts = replyContexts(layers: layers, records: records, ownMargins: ownMargins)
        return layers.flatMap { layer -> [Entry] in
            let layerRecords = records[layer.id] ?? []
            guard asking || layer.revealMode == .guided,
                  SharedMarginPrompts.isLayerPlaybackEligible(layer, records: layerRecords) else { return [] }
            return layerRecords.compactMap { record -> Entry? in
                guard record.isNewToListener, SharedMarginPrompts.isPlayable(record, in: layer),
                      let mediaTimeMs = SharedMarginPrompts.mediaTimeMs(record, in: layer), mediaTimeMs >= 0 else { return nil }
                let placed = record.resolution.localMediaTimeMs != nil && SharedMarginPrompts.isPlayable(record.resolution)
                return Entry(
                    layer: layer, interjection: record, mediaTimeMs: mediaTimeMs,
                    isApproximate: !placed || record.resolution.evidenceClass == .mapInterpolated
                        || record.resolution.evidenceClass == .timestampFallback,
                    replyContext: contexts[record.id]
                )
            }
        }.sorted(by: playsBefore)
    }
}
