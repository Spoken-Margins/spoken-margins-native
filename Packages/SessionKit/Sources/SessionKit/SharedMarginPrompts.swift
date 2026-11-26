public struct ImportedCommentaryPrompt: Identifiable {
    public var id: String { interjection.id }
    public let layer: ImportedCommentaryLayer
    public let interjection: ImportedCommentaryInterjection
    public let index: Int
    public let count: Int
    /// The open item's length, when known. A sender time past it plays after the others (#4347), so the prompt
    /// carries it for `plan` to read wherever the prompt is crossed, jumped to or ordered.
    public let durationMs: Int?

    public init(
        layer: ImportedCommentaryLayer, interjection: ImportedCommentaryInterjection, index: Int, count: Int,
        durationMs: Int? = nil
    ) {
        self.layer = layer
        self.interjection = interjection
        self.index = index
        self.count = count
        self.durationMs = durationMs
    }

    /// How it plays in this copy (#3789), with the item's length.
    public var plan: SharedMarginPlacementPlan { SharedMarginPrompts.plan(interjection, in: layer, durationMs: durationMs) }
    /// Where it plays in the episode: nil for a Margin placed in text only and for one that plays after the others.
    public var mediaTimeMs: Int? { SharedMarginPrompts.mediaTimeMs(interjection, in: layer, durationMs: durationMs) }

    public var senderLabel: String { SharedPacketArrival.snapshotSenderLabel(layer.displayLabel) }
}

/// How a shared Margin plays in the listener's copy (#3789). The words for each case are
/// `SharedMarginPlacementWording.podcastLine(for:)`.
public enum SharedMarginPlacementPlan: Equatable, Sendable {
    /// Placed by the pass. `mediaTimeMs` is nil for a Margin placed in text only.
    case placed(mediaTimeMs: Int?)
    /// Plays at a best-guess time: the sender's own time, or a pass that placed it by map or clock.
    case roughly(mediaTimeMs: Int?)
    /// No usable time: plays after the others, and when tapped.
    case afterOthers
    /// Not offered (another item's layer, or an unplaced Margin outside a podcast).
    case notPlayable
}

public enum SharedMarginPrompts {
    public static func isLayerPlaybackEligible(
        _ layer: ImportedCommentaryLayer,
        records: [ImportedCommentaryInterjection]
    ) -> Bool {
        guard isLayerOn(layer) else { return false }
        return records.contains { isPlayable($0, in: layer) }
    }

    /// Whether the listener can go to a Margin's place in this layer, whatever it would sound like (#4934): the layer is
    /// on, and the Margin has somewhere to be. `isLayerPlaybackEligible` with the voice left out, so a friend's Margin that is
    /// never spoken (`!SharedMarginAudio.canOffer`) is still a place Skim and the lists can take the listener to.
    public static func isLayerPlaceEligible(
        _ layer: ImportedCommentaryLayer,
        records: [ImportedCommentaryInterjection]
    ) -> Bool {
        guard isLayerOn(layer) else { return false }
        return records.contains { plan($0, in: layer, durationMs: nil) != .notPlayable }
    }

    /// Not deleted, not turned off, not matched to the wrong source.
    private static func isLayerOn(_ layer: ImportedCommentaryLayer) -> Bool {
        layer.deletedAt == nil && layer.isEnabled && layer.sourceResolutionStatus != .wrongSource
    }

    public static func position(
        _ interjection: ImportedCommentaryInterjection,
        in layer: ImportedCommentaryLayer? = nil,
        durationMs: Int? = nil
    ) -> Int {
        mediaTimeMs(interjection, in: layer, durationMs: durationMs)
            ?? interjection.resolution.localStartChar
            ?? .max
    }

    public static func isPlayable(_ resolution: ImportedAnchorResolution) -> Bool {
        SharedMarginPlacementStatus.isPlaced(resolution)
    }

    /// Something to play, and somewhere to play it (`plan`). A podcast Margin the placement pass couldn't place still
    /// plays: at the sender's time, or after the others when it has no usable time (#3059, #3789).
    public static func isPlayable(_ interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> Bool {
        // Something to play: a recording, or a note the phone's voice can read (#3365). A note it can't is not offered.
        SharedMarginAudio.canOffer(interjection) && plan(interjection, in: layer, durationMs: nil) != .notPlayable
    }

    /// Where the Margin plays in the episode: its placement in the listener's copy, else the sender's time. Nil for a
    /// Margin placed in text only, and for one that plays after the others.
    public static func mediaTimeMs(
        _ interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer?, durationMs: Int? = nil
    ) -> Int? {
        guard let layer else { return interjection.resolution.localMediaTimeMs }
        switch plan(interjection, in: layer, durationMs: durationMs) {
        case .placed(let ms?), .roughly(let ms?): return ms
        case .placed(nil), .roughly(nil), .afterOthers, .notPlayable: return nil
        }
    }

    /// How one Margin plays in this layer (#3789). Placed Margins play where the pass put them. On a podcast layer
    /// from the same episode, any other Margin plays at the sender's own time, before the pass has run and after it
    /// couldn't find the Margin or found it twice; one with no usable time (none sent, past the end of a copy whose
    /// length is known, or a passage missing from this copy) plays after the others. Other layers keep their rule:
    /// unplaced means not offered.
    public static func plan(
        _ interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer, durationMs: Int?
    ) -> SharedMarginPlacementPlan {
        let resolution = interjection.resolution
        if SharedMarginPlacementStatus.isPlaced(resolution) {
            let approximate = resolution.evidenceClass == .mapInterpolated || resolution.evidenceClass == .timestampFallback
            return approximate
                ? .roughly(mediaTimeMs: resolution.localMediaTimeMs)
                : .placed(mediaTimeMs: resolution.localMediaTimeMs)
        }
        guard layer.itemIdentity.itemType == .podcast, layer.sourceResolutionStatus != .wrongSource else { return .notPlayable }
        guard resolution.evidenceClass != .absentFromRecipientEdition,
              let sender = interjection.anchorEvidence.mediaTimeMs, sender >= 0,
              durationMs.map({ sender <= $0 }) ?? true else { return .afterOthers }
        return .roughly(mediaTimeMs: sender)
    }

    public static func prompts(
        layers: [ImportedCommentaryLayer],
        recordsByLayerID: [String: [ImportedCommentaryInterjection]],
        announcedIDs: Set<String>,
        includeAnnounced: Bool,
        durationMs: Int? = nil
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
                        position(lhs, in: layer, durationMs: durationMs) < position(rhs, in: layer, durationMs: durationMs)
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
                        count: records.count,
                        durationMs: durationMs
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
            // A Margin that plays after the others has no time to cross: it plays when the episode ends (#4347).
            if prompt.plan == .afterOthers {
                return FriendMarginsPlan.episodeEndReached(previous: previous, current: current)
            }
            if let anchor = prompt.mediaTimeMs,
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
            position($0.interjection, in: $0.layer, durationMs: $0.durationMs)
                < position($1.interjection, in: $1.layer, durationMs: $1.durationMs)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
