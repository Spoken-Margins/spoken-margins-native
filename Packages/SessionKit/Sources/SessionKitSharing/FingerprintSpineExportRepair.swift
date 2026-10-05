import Foundation
import SessionKit

/// Makes a stored episode fingerprint spine fit the packet rules before it is shared (#536).
///
/// Sharing a streamed podcast's Margins failed with "episode fingerprint spine is out of bounds":
/// the app captured a spine its own validator, and Build 29's frozen reader, reject. The reader
/// can't change, so the writer repairs what it can and leaves the spine out when it can't. The
/// spine only helps a recipient place Margins; the Margins share without it.
public enum FingerprintSpineExportRepair {
    public static let maximumLandmarks = 500

    /// The spine as the packet may carry it, or nil to leave it out.
    /// - Parameter signatureAssetIDs: the acoustic signatures travelling in the same packet. A
    ///   landmark whose signature isn't among them is dropped, and so is a landmark reusing a
    ///   signature an earlier landmark already uses: Build 29's importer traps on a repeat.
    public static func repaired(
        _ spine: EditionFingerprintSpineArtifact,
        item: SharedItemIdentity,
        signatureAssetIDs: Set<String>
    ) -> EditionFingerprintSpineArtifact? {
        guard (1...500).contains(spine.itemId.count), spine.generatorVersion.count <= 200 else { return nil }
        let episodeGUID = spine.episodeGUID.flatMap { $0.count <= 1_000 ? $0 : nil }
        // A spine naming another episode belongs to another edition.
        if let expected = item.episodeGUID, let actual = episodeGUID, expected != actual { return nil }

        var seenIDs = Set<String>(), seenSignatures = Set<String>()
        let kept = spine.landmarks
            .filter { landmark in
                landmark.sourceMediaStartMs >= 0
                    && landmark.sourceMediaEndMs >= landmark.sourceMediaStartMs
                    && landmark.sourceMediaEndMs - landmark.sourceMediaStartMs <= 30_000
                    && landmark.anchorMediaTimeMs >= 0
                    && landmark.continuityEpoch >= 0
                    && landmark.generatorVersion.count <= 200
                    && signatureAssetIDs.contains(landmark.signatureAssetId)
            }
            .sorted { $0.sourceMediaStartMs < $1.sourceMediaStartMs }
            .filter { seenIDs.insert($0.id).inserted && seenSignatures.insert($0.signatureAssetId).inserted }
        let landmarks = spread(kept, limit: maximumLandmarks).enumerated().map { index, landmark in
            EpisodeFingerprintLandmark(
                id: landmark.id,
                order: index,
                sourceMediaStartMs: landmark.sourceMediaStartMs,
                sourceMediaEndMs: landmark.sourceMediaEndMs,
                anchorMediaTimeMs: landmark.anchorMediaTimeMs,
                continuityEpoch: landmark.continuityEpoch,
                trigger: landmark.trigger,
                provenance: landmark.provenance,
                signatureAssetId: landmark.signatureAssetId,
                transcriptSketchWindowId: landmark.transcriptSketchWindowId,
                generatorVersion: landmark.generatorVersion
            )
        }
        return EditionFingerprintSpineArtifact(
            id: spine.id,
            schemaVersion: spine.schemaVersion,
            itemId: spine.itemId,
            // A feed can name an http:// or non-link reference; packets carry https links only.
            canonicalURL: spine.canonicalURL.flatMap { SpokenMarginsPackageArchive.validHTTPSURL($0) ? $0 : nil },
            episodeGUID: episodeGUID,
            producingEditionDurationMs: spine.producingEditionDurationMs,
            producingEditionSHA256: spine.producingEditionSHA256.flatMap { SpokenMarginsPackageArchive.isSHA256($0) ? $0 : nil },
            createdAt: spine.createdAt,
            generatorVersion: spine.generatorVersion,
            landmarks: landmarks
        )
    }

    /// At most `limit` landmarks, evenly spread over the episode, keeping the first and last.
    static func spread(_ landmarks: [EpisodeFingerprintLandmark], limit: Int) -> [EpisodeFingerprintLandmark] {
        guard landmarks.count > limit, limit > 1 else { return Array(landmarks.prefix(max(0, limit))) }
        return (0..<limit).map { landmarks[$0 * (landmarks.count - 1) / (limit - 1)] }
    }
}
