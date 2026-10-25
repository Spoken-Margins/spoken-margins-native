import Foundation

/// Keeps an episode's fingerprint spine to the landmarks that help place a Margin (#2626).
///
/// Build 35 cut a new "stable post-seek" landmark after every seek for as long as the episode played: one signature
/// file, one offline-asset row and one rewrite of the whole spine record per pass, ids that never repeated. A
/// backgrounded podcast spent its CPU and disk-write allowance on that and iOS killed it. The capture no longer does
/// it, and this trims what the old builds left behind.
///
/// A seek epoch is meant to have one post-seek landmark. Epoch numbers restart in every playback session, so the same
/// number can legitimately appear at two different places in the episode: landmarks of one epoch that start at least
/// `minimumPostSeekSpacingMs` apart are both kept.
public enum EpisodeFingerprintSpineCompaction {
    public static let minimumPostSeekSpacingMs = 60_000

    public struct Result: Equatable, Sendable {
        /// The spine's landmarks in episode order, `order` renumbered from 0.
        public let kept: [EpisodeFingerprintLandmark]
        /// Landmarks to forget, with their signature files and offline-asset rows. May include `adding`.
        public let dropped: [EpisodeFingerprintLandmark]

        public func keeps(signatureAssetId: String) -> Bool {
            kept.contains { $0.signatureAssetId == signatureAssetId }
        }
    }

    /// - Parameters:
    ///   - existing: the stored spine's landmarks. They win over `adding` when both want the same slot.
    ///   - adding: a landmark that was just captured, if any. One with the same signature asset replaces the stored one.
    public static func compact(
        existing: [EpisodeFingerprintLandmark],
        adding: EpisodeFingerprintLandmark? = nil
    ) -> Result {
        var candidates = existing
        if let adding {
            candidates.removeAll { $0.signatureAssetId == adding.signatureAssetId }
            candidates.append(adding)
        }
        let ordered = candidates.sorted {
            ($0.sourceMediaStartMs, $0.signatureAssetId) < ($1.sourceMediaStartMs, $1.signatureAssetId)
        }
        // The stored landmarks come first so that an old one is never displaced by the one just captured.
        let storedIDs = Set(existing.map(\.signatureAssetId))
        let storedFirst = ordered.filter { storedIDs.contains($0.signatureAssetId) }
            + ordered.filter { !storedIDs.contains($0.signatureAssetId) }
        var keptPostSeekStarts: [Int: [Int]] = [:]
        var keptIDs = Set<String>()
        var dropped: [EpisodeFingerprintLandmark] = []
        for landmark in storedFirst {
            if landmark.trigger == .stablePostSeek {
                let starts = keptPostSeekStarts[landmark.continuityEpoch, default: []]
                if starts.contains(where: { abs($0 - landmark.sourceMediaStartMs) < minimumPostSeekSpacingMs }) {
                    dropped.append(landmark)
                    continue
                }
                keptPostSeekStarts[landmark.continuityEpoch, default: []].append(landmark.sourceMediaStartMs)
            }
            keptIDs.insert(landmark.signatureAssetId)
        }
        let kept = ordered.filter { keptIDs.contains($0.signatureAssetId) }.enumerated().map { index, value in
            EpisodeFingerprintLandmark(
                id: value.id,
                order: index,
                sourceMediaStartMs: value.sourceMediaStartMs,
                sourceMediaEndMs: value.sourceMediaEndMs,
                anchorMediaTimeMs: value.anchorMediaTimeMs,
                continuityEpoch: value.continuityEpoch,
                trigger: value.trigger,
                provenance: value.provenance,
                signatureAssetId: value.signatureAssetId,
                transcriptSketchWindowId: value.transcriptSketchWindowId,
                generatorVersion: value.generatorVersion
            )
        }
        return Result(kept: kept, dropped: dropped)
    }
}
