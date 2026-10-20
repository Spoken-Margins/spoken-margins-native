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
    /// ones, drop contradictions again, then let an edition rejection override everything.
    public static func fuse(
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
