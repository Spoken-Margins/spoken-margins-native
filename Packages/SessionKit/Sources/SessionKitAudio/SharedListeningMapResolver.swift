import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Places a shared Listening Map's scene starts on the recipient's own copy of an
/// episode with the same acoustic resolver that places shared Margins. The decision
/// rules (every start placed by direct evidence, in order) are in
/// `SharedListeningMapPlacement`.
public enum SharedListeningMapResolver {
    /// - Parameter signatureData: the sender's landmark signature for an asset id, or
    ///   nil when the packet didn't carry it.
    public static func resolve(
        proposal: PortableListeningMapProposalArtifact,
        spine: EditionFingerprintSpineArtifact,
        signatureData: @Sendable (String) -> Data?,
        recipientAudioURL: URL,
        recipientEditionSHA256: String,
        itemId: String,
        projectionId: String,
        strongSourceIdentity: Bool
    ) async throws -> SharedListeningMapPlacement.Outcome {
        if let producing = spine.producingEditionSHA256, producing == recipientEditionSHA256 {
            return .placed(EpisodeFingerprintAlignment.makeProjection(
                id: projectionId,
                itemId: itemId,
                proposalId: proposal.id,
                recipientEditionSHA256: recipientEditionSHA256,
                matches: [],
                exactEdition: true
            ))
        }
        let sceneQueries: [SharedListeningMapPlacement.SceneQuery]
        switch SharedListeningMapPlacement.sceneQueries(proposal: proposal, landmarks: spine.landmarks) {
        case .failure(let refusal): return .notPlaced(refusal)
        case .success(let queries): sceneQueries = queries
        }
        let queries = sceneQueries.map { scene in
            PodcastPortableAnchorQuery(
                packageScopedId: scene.sceneId,
                senderMediaTimeMs: scene.senderStartMs,
                evidence: scene.landmarks.compactMap { landmark in
                    signatureData(landmark.signatureAssetId).map {
                        PodcastAcousticEvidenceQuery(
                            id: landmark.signatureAssetId,
                            signatureData: $0,
                            anchorOffsetMs: SharedListeningMapPlacement.anchorOffsetMs(
                                sceneStartMs: scene.senderStartMs,
                                landmark: landmark
                            )
                        )
                    }
                },
                // Declared evidence that is missing must leave the scene unplaced,
                // never fall back to the sender's timestamp.
                evidenceWasDeclared: true
            )
        }
        if let missing = queries.first(where: { $0.evidence.isEmpty }) {
            let scene = proposal.scenes.first { $0.id == missing.packageScopedId }
            return .notPlaced(SharedListeningMapPlacement.Refusal(
                sceneId: missing.packageScopedId,
                sceneLabel: scene.map(SharedListeningMapPlacement.label(for:)),
                reason: .noEvidence
            ))
        }
        let resolutions = try await PodcastAcousticAnchorResolver.resolve(
            queries: queries,
            recipientAudioURL: recipientAudioURL,
            senderExactEditionSHA256: spine.producingEditionSHA256,
            senderDurationMs: spine.producingEditionDurationMs,
            strongSourceIdentity: strongSourceIdentity
        )
        let recipientDurationMs = await durationMs(of: recipientAudioURL)
        return SharedListeningMapPlacement.decide(
            proposal: proposal,
            queries: sceneQueries,
            resolutions: resolutions,
            senderDurationMs: spine.producingEditionDurationMs,
            recipientDurationMs: recipientDurationMs,
            projectionId: projectionId,
            itemId: itemId,
            recipientEditionSHA256: recipientEditionSHA256
        )
    }

    private static func durationMs(of url: URL) async -> Int? {
        #if canImport(AVFoundation)
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? Int((seconds * 1_000).rounded()) : nil
        #else
        return nil
        #endif
    }
}
