import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// The last step of an episode-map run (#4227): the job's final stage, the fingerprint spine, the phrase sketch, the
    /// proposal and the projection, and the release of the run's protection on the item's fingerprint-map assets, as one
    /// transaction that first checks the item still has a row. A permanent delete asked while the run finished lands
    /// before the check (nothing is written, and this returns false) or after the commit (the delete takes these rows with
    /// the item). Before, the saves were separate, and a delete between them let the run write rows for an item that was
    /// gone. A caller that gets false stops the run as cancelled.
    ///
    /// This covers the run's commit step only. The ledger's asset rows written earlier in the run (`ledger.commit`) are
    /// not guarded here.
    @discardableResult
    public func commitEpisodeMapRun(
        itemId: String,
        job: EpisodeMapPreparationJob,
        spine: EditionFingerprintSpineArtifact,
        sketch: TranscriptPhraseSketchArtifact,
        proposal: PortableListeningMapProposalArtifact,
        projection: ResolvedListeningMapProjection
    ) throws -> Bool {
        try withSessionTransaction {
            guard try hasItemRow(id: itemId) else { return false }
            try saveEpisodeMapPreparationJob(job)
            try saveEditionFingerprintSpine(spine)
            try saveTranscriptPhraseSketch(sketch)
            try savePortableListeningMapProposal(proposal, itemId: itemId)
            try saveResolvedListeningMapProjection(projection)
            for asset in try loadOwnedOfflineAssets(itemId: itemId) where asset.category == .fingerprintMap {
                _ = try updateOwnedOfflineAsset(id: asset.id) { $0.protections.remove(.activeEpisodeMapPreparation) }
            }
            return true
        }
    }
}
