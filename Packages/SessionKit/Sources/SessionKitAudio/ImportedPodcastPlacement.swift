import Foundation
import SessionKit

/// The rules that place an imported podcast Margin on the listener's copy of the episode, and that say
/// what a layer's Margins add up to. The app's placement pass reads the evidence files, runs the acoustic
/// and map resolvers and saves the result. These functions take what it found and decide.
public enum ImportedPodcastPlacement {
    /// The transcript step's algorithm version when the pass has no transcript to read. Persisted with
    /// the resolution, so it must not change.
    public static let missingTranscriptAlgorithmVersion = "podcast-transcript-anchor.v1"

    /// The layers a placement pass works on, each with its Margins (`ImportedPodcastPlacementPolicy` holds the rule).
    public static func podcastLayerRecords(
        layers: [ImportedCommentaryLayer],
        loadRecords: (ImportedCommentaryLayer) -> [ImportedCommentaryInterjection]?
    ) -> [(ImportedCommentaryLayer, [ImportedCommentaryInterjection])] {
        ImportedPodcastPlacementPolicy.podcastLayerRecords(layers: layers, loadRecords: loadRecords)
    }

    /// Whether reading the recipient's audio into a transcript could still place this Margin: it is not
    /// placed inline yet and its sender context has enough words to match.
    public static func recordNeedsTranscript(_ record: ImportedCommentaryInterjection) -> Bool {
        !PodcastAnchorFusionResolver.isInlinePlacement(record.resolution)
            && PodcastTranscriptAnchorResolver.hasUsableContext(record.anchorEvidence)
    }

    /// Turns the transcript and acoustic evidence for one layer's Margins into one placement each. The
    /// order is part of the rule: fuse each Margin, drop contradictions, interpolate between the verified
    /// ones, drop contradictions again, let an edition rejection override everything, and last, when the
    /// pass knows the layer, place the Margins that sent only a clock time (`placingClockOnlyMargins`).
    public static func fuse(
        queries: [PodcastPortableAnchorQuery],
        records: [ImportedCommentaryInterjection],
        acoustic: [String: ImportedAnchorResolution],
        recipientTranscript: TranscriptTimeline?,
        layer: ImportedCommentaryLayer? = nil,
        recipientDurationMs: Int? = nil
    ) -> [String: ImportedAnchorResolution] {
        let evidenced = fuseEvidence(
            queries: queries, records: records, acoustic: acoustic, recipientTranscript: recipientTranscript)
        guard let layer else { return evidenced }
        return placingClockOnlyMargins(
            evidenced, records: records, layer: layer, recipientDurationMs: recipientDurationMs)
    }

    /// How far a placed Margin may sit from its sender's time before it says the two copies' clocks differ.
    /// Acoustic matches land within about a second of the true spot on the same file; an inserted or swapped
    /// advert moves everything after it by tens of seconds.
    public static let clockAgreementToleranceMs = 2_000

    /// Places the Margins that sent nothing to find their spot by, only the sender's clock time, at that time,
    /// as an approximate `timestampFallback` (#3041). The web app's packets are all like this: it streams the
    /// episode, so it has no bytes to fingerprint or hash. Left unplaced, such a Margin never played during
    /// playback, only when tapped, which plays it at the same time (`SharedMarginPlaybackPosition`, #158).
    /// "Unplaced moments play at the sender's time, labelled 'about here'. Never silently wrong."
    /// (`docs/design/sharing-with-a-friend.md`).
    ///
    /// Only when nothing in the pass says the clock is wrong:
    /// - no Margin was found on a different edition (an edition rejection);
    /// - every Margin of the layer that the pass did place sits within `clockAgreementToleranceMs` of its
    ///   sender's time, so the two copies' clocks agree wherever there is evidence;
    /// - the sender's time falls inside the listener's copy, when its length is known.
    /// A Margin that sent evidence and wasn't found, or is ambiguous, keeps that answer.
    public static func placingClockOnlyMargins(
        _ resolutions: [String: ImportedAnchorResolution],
        records: [ImportedCommentaryInterjection],
        layer: ImportedCommentaryLayer,
        recipientDurationMs: Int?
    ) -> [String: ImportedAnchorResolution] {
        guard layer.itemIdentity.itemType == .podcast, layer.sourceResolutionStatus != .wrongSource,
              !resolutions.values.contains(where: PodcastAcousticAnchorResolver.isEditionRejection) else {
            return resolutions
        }
        let clocksDisagree = records.contains { record in
            guard let resolution = resolutions[record.packageScopedId],
                  PodcastAnchorFusionResolver.isInlinePlacement(resolution), !resolution.isAmbiguous,
                  let placed = resolution.localMediaTimeMs, let sender = record.anchorEvidence.mediaTimeMs else {
                return false
            }
            return abs(placed - sender) > clockAgreementToleranceMs
        }
        guard !clocksDisagree else { return resolutions }
        var result = resolutions
        for record in records {
            guard let resolution = resolutions[record.packageScopedId],
                  resolution.evidenceClass == .unresolved, !resolution.isAmbiguous,
                  !record.sentPositionEvidence(in: layer),
                  let sender = record.anchorEvidence.mediaTimeMs, sender >= 0 else { continue }
            if let recipientDurationMs, recipientDurationMs > 0, sender >= recipientDurationMs { continue }
            result[record.packageScopedId] = ImportedAnchorResolution(
                evidenceClass: .timestampFallback,
                localMediaTimeMs: sender,
                algorithmVersion: clockOnlyAlgorithmVersion
            )
        }
        return result
    }

    /// Persisted with a clock-only placement, so it must not change.
    public static let clockOnlyAlgorithmVersion = "podcast-anchor-sender-clock.v1"

    private static func fuseEvidence(
        queries: [PodcastPortableAnchorQuery],
        records: [ImportedCommentaryInterjection],
        acoustic: [String: ImportedAnchorResolution],
        recipientTranscript: TranscriptTimeline?
    ) -> [String: ImportedAnchorResolution] {
        let monotonicResolutions = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
            queries: queries,
            resolutions: Dictionary(uniqueKeysWithValues: records.map { record in
                let transcriptResolution = recipientTranscript.map {
                    PodcastTranscriptAnchorResolver.resolve(
                        anchor: record.anchorEvidence,
                        recipientTimeline: $0
                    )
                } ?? ImportedAnchorResolution(
                    evidenceClass: .unresolved,
                    algorithmVersion: missingTranscriptAlgorithmVersion
                )
                let acousticResolution = acoustic[record.packageScopedId]
                    ?? ImportedAnchorResolution(evidenceClass: .unresolved)
                return (
                    record.packageScopedId,
                    PodcastAnchorFusionResolver.fuse(
                        transcript: transcriptResolution,
                        acoustic: acousticResolution
                    )
                )
            })
        )
        let projectedResolutions = PodcastAnchorFusionResolver.interpolatingBetweenVerifiedAnchors(
            queries: queries,
            resolutions: monotonicResolutions
        )
        return PodcastAnchorFusionResolver.enforcingEditionRejection(
            acoustic: acoustic,
            resolutions: PodcastAnchorFusionResolver.enforcingMonotonicOrder(
                queries: queries,
                resolutions: projectedResolutions
            )
        )
    }

    /// Stores a pass's placements on the layer's Margins and records which file they were made for. A
    /// verified placement on the same known file survives a weaker result (see
    /// `PodcastAnchorFusionResolver.preservingVerifiedPlacement`). The layer's status is worked out from
    /// the Margins as they are after that, not from the proposed values.
    public static func apply(
        _ placements: [String: ImportedAnchorResolution],
        to records: [ImportedCommentaryInterjection],
        layer: inout ImportedCommentaryLayer,
        recipientDigest: String,
        hasTranscript: Bool
    ) -> [ImportedCommentaryInterjection] {
        var updated = records
        for index in updated.indices {
            if let resolution = placements[updated[index].packageScopedId] {
                updated[index].resolution = PodcastAnchorFusionResolver.preservingVerifiedPlacement(
                    previous: updated[index].resolution, proposed: resolution,
                    previousEdition: layer.resolvedRecipientEditionSHA256,
                    currentEdition: recipientDigest, hasTranscript: hasTranscript)
            }
        }
        layer.resolvedRecipientEditionSHA256 = recipientDigest
        layer.sourceResolutionStatus = layerStatus(for: updated.map(\.resolution))
        return updated
    }

    /// What a layer's Margins add up to: resolved when every one plays inline, ambiguous when any is
    /// ambiguous, unavailable when none is on the listener's copy, otherwise context only.
    public static func layerStatus(for resolutions: [ImportedAnchorResolution]) -> ImportedSourceResolutionStatus {
        if resolutions.allSatisfy(PodcastAnchorFusionResolver.isInlinePlacement) {
            return .resolved
        } else if resolutions.contains(where: { $0.evidenceClass == .ambiguous }) {
            return .ambiguous
        } else if resolutions.allSatisfy({ $0.evidenceClass == .absentFromRecipientEdition }) {
            return .unavailable
        } else {
            return .contextOnly
        }
    }
}
