import Foundation
import SessionKit

/// The edits to one Margin's podcast anchor evidence, for a caller off the main actor (#2509, fix class
/// `write-behind`). Each one reads the Margin, changes it with `PodcastAnchorEvidenceRecord` and saves it in one
/// transaction, so a field another writer saved in between (its transcript, its context status) is never written back
/// stale. Callers run them through `StoreReader.readInOrder(orderKey)`, so a capture's "pending", its evidence and its
/// failure notes land in the order they were asked, and the screen refresh that follows sees the last one.
public enum PodcastAnchorEvidenceEdits {
    public static let orderKey = "podcast-anchor-evidence"

    public enum Change: Equatable, Sendable {
        /// `PodcastAnchorEvidenceRecord.merging`
        case merge([CapturedPodcastAnchorEvidence], sourceExactEditionSHA256: String?)
        /// `PodcastAnchorEvidenceRecord.markingUnavailable`
        case markUnavailable(reason: String)
        /// `PodcastAnchorEvidenceRecord.markingPendingLocalCapture`
        case markPendingLocalCapture
        /// `PodcastAnchorEvidenceRecord.recordingFailureReason`
        case recordFailureReason(String)
    }

    /// Applies `change` to the Margin `interjectionId` of `itemId` in `sessionId` and returns it as saved. Nil, with
    /// nothing written, when there is no such Margin (it was never saved, or belongs to another item).
    public static func apply(
        _ change: Change,
        interjectionId: String,
        itemId: String,
        sessionId: String,
        in store: SQLiteSessionStore
    ) throws -> Interjection? {
        try store.withSessionTransaction {
            guard let stored = try store.loadInterjection(id: interjectionId, sessionId: sessionId),
                  stored.itemId == itemId else { return nil }
            let changed: Interjection
            switch change {
            case .merge(let evidence, let sha):
                changed = PodcastAnchorEvidenceRecord.merging(evidence, sourceExactEditionSHA256: sha, into: stored)
            case .markUnavailable(let reason):
                changed = PodcastAnchorEvidenceRecord.markingUnavailable(stored, reason: reason)
            case .markPendingLocalCapture:
                changed = PodcastAnchorEvidenceRecord.markingPendingLocalCapture(stored)
            case .recordFailureReason(let reason):
                changed = PodcastAnchorEvidenceRecord.recordingFailureReason(reason, on: stored)
            }
            try store.saveInterjection(changed)
            return changed
        }
    }
}
