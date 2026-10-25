import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// Deletes the jobs in `candidates` that are still stale now (#2505). A Library reload decides which jobs are stale
    /// from rows it read a moment ago and hands the ids to a background step; a job re-queued for the same item in
    /// between has the same id, so each is checked again against the store before it goes. Returns the ids deleted.
    @discardableResult
    public func deleteStaleAudioPreparationJobs(among candidates: [String]) throws -> [String] {
        guard !candidates.isEmpty else { return [] }
        let stale = Set(AudioPreparationPresentation(
            items: try listItemSummaries(), sessions: try loadSessions(), manifests: [],
            jobs: try loadAudioPreparationJobs(), activeItemId: nil).staleJobIds)
        let ids = candidates.filter(stale.contains)
        try deleteAudioPreparationJobs(ids: ids)
        return ids
    }
}
