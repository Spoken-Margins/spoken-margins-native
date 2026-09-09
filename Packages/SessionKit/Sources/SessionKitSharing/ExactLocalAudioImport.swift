import Foundation
import SessionKit

/// Recipient-supplied local media has no URL identity or edition fallback.
/// The caller must obtain the recipient digest from the actual owned audio.
public enum ExactLocalAudioImport {
    public static func matches(_ source: SharedItemIdentity, _ recipient: SharedItemIdentity) -> Bool {
        guard source.itemType == .other, recipient.itemType == .other,
              let digest = source.exactEditionSHA256, digest.count == 64,
              digest == recipient.exactEditionSHA256,
              let sourceDuration = source.durationMs, let duration = recipient.durationMs,
              sourceDuration > 0, duration > 0,
              abs(sourceDuration - duration) <= 250 else { return false }
        return true
    }

    public static func resolution(
        anchor: PortableAnchorEvidence,
        source: SharedItemIdentity,
        recipient: SharedItemIdentity
    ) -> ImportedAnchorResolution {
        guard matches(source, recipient), anchor.anchorType == .media,
              let time = anchor.mediaTimeMs, let duration = recipient.durationMs,
              time >= 0, time < duration else {
            return ImportedAnchorResolution(evidenceClass: .unresolved)
        }
        return ImportedAnchorResolution(
            evidenceClass: .exactEdition,
            localMediaTimeMs: time,
            confidence: 1
        )
    }

    public static func projection(
        proposal: PortableListeningMapProposalArtifact,
        source: SharedItemIdentity,
        recipient: SharedItemIdentity,
        itemId: String
    ) throws -> ResolvedListeningMapProjection {
        guard matches(source, recipient), let duration = recipient.durationMs,
              let sourceDuration = source.durationMs,
              !proposal.scenes.isEmpty,
              Set(proposal.scenes.map(\.id)).count == proposal.scenes.count,
              proposal.scenes.map(\.order) == Array(proposal.scenes.indices) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Local audio map requires the exact source edition and ordered scenes")
        }
        var previousEnd = 0
        for scene in proposal.scenes {
            guard scene.startAnchor.anchorType == .media, scene.endAnchor.anchorType == .media,
                  let start = scene.startAnchor.mediaTimeMs, let end = scene.endAnchor.mediaTimeMs,
                  start >= previousEnd, start < duration, end > start,
                  end <= max(duration, sourceDuration),
                  scene.eligibility != .eligible || (scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && scene.summaryProvenance != nil) else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("Local audio map contains overlapping, out-of-range, or ungrounded scenes")
            }
            previousEnd = end
        }
        return EpisodeFingerprintAlignment.makeProjection(
            id: "local-audio-\(itemId)-\(proposal.id)", itemId: itemId,
            proposalId: proposal.id, recipientEditionSHA256: recipient.exactEditionSHA256,
            matches: [], exactEdition: true
        )
    }
}
