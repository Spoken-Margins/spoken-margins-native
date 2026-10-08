import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// Resets imported podcast placements made on another edition of the listener's file, before a placement
    /// pass on `editionSHA256` writes new ones. A position in the old file can be wrong in the new one, so the
    /// reset Margins don't play until the pass places them; the screen shows them as being placed (#872).
    /// Moved unchanged from the app model.
    public func invalidateImportedPodcastPlacements(itemId: String, editionSHA256 digest: String) throws {
        for var layer in try loadImportedCommentaryLayers(itemId: itemId)
        where layer.deletedAt == nil && layer.itemIdentity.itemType == .podcast
            && layer.resolvedRecipientEditionSHA256 != digest {
            layer.sourceResolutionStatus = .pending
            layer.resolvedRecipientEditionSHA256 = nil
            try saveImportedCommentaryLayer(layer)
            for var note in try loadImportedCommentaryInterjections(layerId: layer.id) {
                note.resolution = ImportedAnchorResolution(evidenceClass: .unresolved)
                try saveImportedCommentaryInterjection(note)
            }
        }
        if let projection = try loadResolvedListeningMapProjection(itemId: itemId),
           projection.recipientEditionSHA256 != digest {
            try saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                id: projection.id, itemId: itemId, proposalId: projection.proposalId,
                recipientEditionSHA256: digest, points: [], intervals: []))
        }
    }
}
