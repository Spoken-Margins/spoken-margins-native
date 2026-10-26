import Foundation
import SessionKit

extension OfflinePreparationRun {
    /// The explicit audio preparation queue as a run reads it, once a second while a continued task is open (#2508).
    /// Pure over the store, so the app calls it from `StoreReader` instead of the main thread.
    /// Includes manifests of jobs the running banner already knows, even after queue removal.
    public static func explicitJobs(store: SQLiteSessionStore, including previous: [Job] = []) -> [Job] {
        guard let stored = try? store.loadAudioPreparationJobs() else { return previous }
        let allJobs = stored.filter { !$0.isCancelled && $0.policy == .explicit }.map { job in
            let manifest = try? store.loadPreparedAudioManifest(id: job.manifestId)
            return Job(
                id: job.id, manifestId: job.manifestId,
                requestedAt: job.requestedAt, policy: job.policy,
                state: manifest?.state ?? .failed,
                completedChunks: manifest?.committedChunkCount ?? job.nextChunkIndex,
                plannedChunks: manifest?.plannedChunkCount ?? 0
            )
        }
        // Old failures aren't part of a new run. A failure this banner saw happen stays in it.
        let tracked = openExplicitRequests(allJobs).union(previous.map {
            RequestKey(jobId: $0.id, requestedAt: $0.requestedAt)
        })
        let jobs = allJobs.filter { tracked.contains(.init(jobId: $0.id, requestedAt: $0.requestedAt)) }
        let current = Set(jobs.map { RequestKey(jobId: $0.id, requestedAt: $0.requestedAt) })
        return jobs + previous.filter {
            !current.contains(.init(jobId: $0.id, requestedAt: $0.requestedAt))
        }.map { job in
            resolvingRemovedJob(job, manifest: try? store.loadPreparedAudioManifest(id: job.manifestId))
        }
    }
}
