import Foundation
import SessionKit

/// The reads and deletes behind "clean up episode-map jobs" (#2509, fix class `store-write`). At launch the app
/// decoded every job, asked about a saved map per expired one and deleted rows one by one on the main thread; on
/// Delete Forever it read the item's jobs and deleted them there. The app now runs both on a background task, in
/// line with the automatic-queueing saves, which share `AutomaticEpisodeMapJobs.orderKey`.
public enum EpisodeMapJobCleanup {
    /// A job unfinished for this long, or cancelled, is cleaned up at launch.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// One job due for clean-up. `hasMap` says a saved map exists, so only its transient folder goes.
    public struct ExpiredJob: Equatable, Sendable {
        public let jobId: String
        public let itemId: String
        public let hasMap: Bool
    }

    static func isExpired(_ job: EpisodeMapPreparationJob, now: Date) -> Bool {
        job.isCancelled || job.requestedAt < now.addingTimeInterval(-retention)
    }

    /// The jobs due for clean-up, in the store's job order. Reads; deletes nothing. The app removes the files first
    /// and then calls `deleteExpired`, so a crash between the two leaves a job to try again, as before.
    public static func expiredJobs(now: Date, store: SQLiteSessionStore) -> [ExpiredJob] {
        ((try? store.loadEpisodeMapPreparationJobs()) ?? [])
            .filter { isExpired($0, now: now) }
            .map { job in
                ExpiredJob(
                    jobId: job.id,
                    itemId: job.itemId,
                    hasMap: (try? store.hasEditionFingerprintSpine(itemId: job.itemId)) == true
                )
            }
    }

    /// The jobs of `expired` that are still expired, with `hasMap` read again. The app calls it right before it removes
    /// files, so a job asked for again, or a map finished, since `expiredJobs` ran keeps its folder (#2509).
    public static func stillExpired(_ expired: [ExpiredJob], now: Date, store: SQLiteSessionStore) -> [ExpiredJob] {
        expired.compactMap { entry in
            guard let job = try? store.loadEpisodeMapPreparationJob(id: entry.jobId), isExpired(job, now: now) else { return nil }
            return ExpiredJob(
                jobId: job.id,
                itemId: job.itemId,
                hasMap: (try? store.hasEditionFingerprintSpine(itemId: job.itemId)) == true
            )
        }
    }

    /// Deletes the given jobs and the item's transient-transcript ledger rows. A job the listener asked for again
    /// since `expiredJobs` ran (saved over, so no longer expired) is kept. Returns the ids it deleted.
    @discardableResult
    public static func deleteExpired(_ expired: [ExpiredJob], now: Date, store: SQLiteSessionStore) -> [String] {
        var deleted: [String] = []
        for entry in expired {
            guard let job = try? store.loadEpisodeMapPreparationJob(id: entry.jobId) else { continue }
            guard isExpired(job, now: now) else { continue }
            for asset in (try? store.loadOwnedOfflineAssets(itemId: job.itemId)) ?? []
            where asset.category == .transientEpisodeTranscript {
                try? store.deleteOwnedOfflineAsset(id: asset.id)
            }
            if (try? store.deleteEpisodeMapPreparationJob(id: job.id)) != nil { deleted.append(job.id) }
        }
        return deleted
    }

    /// Deletes every job of an item (Delete Forever). Returns how many it deleted.
    @discardableResult
    public static func deleteJobs(itemId: String, store: SQLiteSessionStore) -> Int {
        var count = 0
        for job in (try? store.loadEpisodeMapPreparationJobs(itemId: itemId)) ?? [] {
            if (try? store.deleteEpisodeMapPreparationJob(id: job.id)) != nil { count += 1 }
        }
        return count
    }
}
