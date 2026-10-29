import Foundation

/// What the Preparing Audio screen shows, worked out from stored jobs and manifests (#980).
///
/// Everything here is a pure function of its inputs. Reading and writing the store, the notice
/// date in UserDefaults and the published properties stay in the app model, in the same order
/// as before: `refreshAudioPreparationPresentation` deletes stale job rows between its reads
/// and the projection, so the projection never sees a job that is about to be deleted.
public enum AudioPreparationQueueProjection {
    /// UserDefaults key for the newest completion the "Ready offline" notice has already named.
    public static let lastNoticeDateDefaultsKey = "lastPreparedAudioNoticeDateV1"
    /// UserDefaults key for the items the listener removed from automatic audio preparation.
    public static let suppressedItemIdsDefaultsKey = "suppressedAudioPreparationItemIdsV1"
    /// The most "recently prepared" rows the screen lists.
    public static let recentlyPreparedLimit = 10
    /// With no stored notice date, only completions from the last day are announced.
    public static let noticeLookback: TimeInterval = 24 * 60 * 60

    /// Whether `neighbor` is in `job`'s move tier: the same policy, the same "has a chunk limit",
    /// and not the item that is playing (which is pinned and never moves).
    public static func sharesMoveTier(_ job: AudioPreparationJob, _ neighbor: AudioPreparationJob?, activeItemId: String?) -> Bool {
        guard let neighbor else { return false }
        return neighbor.policy == job.policy
            && (neighbor.maximumChunkCount != nil) == (job.maximumChunkCount != nil)
            && neighbor.itemId != activeItemId
    }

    /// The queue the listener sees: stored jobs without cancelled or stale ones, in preparation order.
    public static func orderedJobs(_ stored: [AudioPreparationJob], staleJobIds: Set<String>, activeItemId: String?) -> [AudioPreparationJob] {
        stored
            .filter { !$0.isCancelled && !staleJobIds.contains($0.id) }
            .sorted { LibraryAudioPreparationQueue.precedes($0, $1, activeItemId: activeItemId) }
    }

    /// One row per job in `jobs` (already ordered). A job whose manifest is gone shows as failed.
    public static func queueRows(
        jobs: [AudioPreparationJob],
        manifestsById: [String: PreparedAudioManifestSummary],
        titlesByItemId: [String: String],
        activeItemId: String?
    ) -> [AudioPreparationQueueRow] {
        jobs.enumerated().map { index, job in
            let manifest = manifestsById[job.manifestId]
            let previous = index > 0 ? jobs[index - 1] : nil
            let next = jobs.indices.contains(index + 1) ? jobs[index + 1] : nil
            let isPinnedActive = job.itemId == activeItemId
            return AudioPreparationQueueRow(
                id: job.id,
                itemId: job.itemId,
                title: titlesByItemId[job.itemId] ?? job.itemId,
                policy: job.policy,
                state: manifest?.state ?? .failed,
                completedChunkCount: min(
                    manifest?.committedChunkCount ?? job.nextChunkIndex,
                    job.maximumChunkCount ?? manifest?.plannedChunkCount ?? .max
                ),
                plannedChunkCount: min(
                    manifest?.plannedChunkCount ?? job.maximumChunkCount ?? 0,
                    job.maximumChunkCount ?? .max
                ),
                requestedAt: job.requestedAt,
                updatedAt: manifest?.updatedAt ?? job.requestedAt,
                failureCode: job.lastFailureCode ?? manifest?.failureCode,
                isActivePlaybackItem: isPinnedActive,
                canMoveEarlier: !isPinnedActive && sharesMoveTier(job, previous, activeItemId: activeItemId),
                canMoveLater: !isPinnedActive && sharesMoveTier(job, next, activeItemId: activeItemId)
            )
        }
    }

    /// The "recently prepared" list: finished offline audio, one row per item (the newest), newest
    /// first, at most `recentlyPreparedLimit`.
    public static func recentlyPrepared(
        manifests: [PreparedAudioManifestSummary],
        titlesByItemId: [String: String]
    ) -> [RecentlyPreparedAudioRow] {
        var seenItemIds = Set<String>()
        return manifests
            .filter { $0.state == .readyOffline && $0.artifact != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { manifest -> RecentlyPreparedAudioRow? in
                guard seenItemIds.insert(manifest.itemId).inserted else { return nil }
                return RecentlyPreparedAudioRow(
                    id: manifest.id,
                    itemId: manifest.itemId,
                    title: titlesByItemId[manifest.itemId] ?? manifest.itemId,
                    completedAt: manifest.updatedAt,
                    durationMs: manifest.artifact?.durationMs ?? 0
                )
            }
            .prefix(recentlyPreparedLimit)
            .map { $0 }
    }

    /// Rows after one chunk of progress, without reloading the store: the rows already shown, kept
    /// only for jobs that remain, re-sorted, with the job being prepared (`currentJob`) taking its
    /// numbers from `manifest`.
    public static func rows(
        _ shown: [AudioPreparationQueueRow],
        afterProgressOn manifest: PreparedAudioManifest,
        currentJob job: AudioPreparationJob?,
        remainingJobs: [AudioPreparationJob],
        activeItemId: String?
    ) -> [AudioPreparationQueueRow] {
        let jobsByID = Dictionary(remainingJobs.filter { !$0.isCancelled }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let retained = shown.filter { jobsByID[$0.id] != nil }.sorted {
            LibraryAudioPreparationQueue.precedes(jobsByID[$0.id]!, jobsByID[$1.id]!, activeItemId: activeItemId)
        }
        return retained.enumerated().map { index, row in
            let current = row.id == job?.id
            let previous = index > 0 ? jobsByID[retained[index - 1].id] : nil
            let next = index + 1 < retained.count ? jobsByID[retained[index + 1].id] : nil
            let rowJob = jobsByID[row.id]!
            let pinned = row.itemId == activeItemId
            return AudioPreparationQueueRow(
                id: row.id, itemId: row.itemId, title: row.title,
                policy: rowJob.policy,
                state: current ? manifest.state : row.state,
                completedChunkCount: current ? min(manifest.chunks.count, job?.maximumChunkCount ?? .max) : row.completedChunkCount,
                plannedChunkCount: current ? min(manifest.plannedChunkCount, job?.maximumChunkCount ?? .max) : row.plannedChunkCount,
                requestedAt: row.requestedAt, updatedAt: current ? manifest.updatedAt : row.updatedAt,
                failureCode: current ? job?.lastFailureCode : row.failureCode,
                isActivePlaybackItem: pinned,
                canMoveEarlier: !pinned && sharesMoveTier(rowJob, previous, activeItemId: activeItemId),
                canMoveLater: !pinned && sharesMoveTier(rowJob, next, activeItemId: activeItemId))
        }
    }

    /// The user priority that puts one job ahead of every job that has one. Only the selected job
    /// takes it: ranking the whole queue would demote every future import behind existing work.
    public static func nextUserPriority(among jobs: [AudioPreparationJob]) -> Int {
        max(Int.min + 1, jobs.compactMap(\.userPriority).min() ?? 0) - 1
    }

    /// The jobs to save after moving `id` one place earlier (`offset` -1) or later (+1) within its
    /// tier, each with its new `userPriority` (its position in the tier), in the order to save them.
    /// Nil when nothing moves: no such job, the playing item, or already at the end of its tier.
    public static func reorderedTier(
        of jobs: [AudioPreparationJob],
        moving id: String,
        by offset: Int,
        activeItemId: String?
    ) -> [AudioPreparationJob]? {
        guard let selected = jobs.first(where: { $0.id == id }), selected.itemId != activeItemId else { return nil }
        var tier = jobs
            .filter {
                $0.policy == selected.policy
                    && ($0.maximumChunkCount != nil) == (selected.maximumChunkCount != nil)
                    && $0.itemId != activeItemId
            }
            .sorted { LibraryAudioPreparationQueue.precedes($0, $1, activeItemId: nil) }
        guard let currentIndex = tier.firstIndex(where: { $0.id == id }) else { return nil }
        let destination = currentIndex + offset
        guard tier.indices.contains(destination) else { return nil }
        tier.swapAt(currentIndex, destination)
        return tier.enumerated().map { priority, job in
            var job = job
            job.userPriority = priority
            return job
        }
    }

    /// The "Ready offline" notice for completions since the last one announced.
    public struct PreparedAudioNotice: Equatable, Sendable {
        public let message: String
        /// The newest completion named; the app stores it as the new notice boundary.
        public let newestCompletedAt: Date
    }

    /// Names one title, or the newest plus a count. `lastNoticeTimestamp` is the stored notice date
    /// (seconds since 1970), if any; without it only the last day's completions count. `recentlyPrepared`
    /// is newest first, so the first newer row is the newest.
    public static func preparedAudioNotice(
        recentlyPrepared: [RecentlyPreparedAudioRow],
        lastNoticeTimestamp: Double?,
        now: Date
    ) -> PreparedAudioNotice? {
        let boundary = lastNoticeTimestamp.map(Date.init(timeIntervalSince1970:))
            ?? now.addingTimeInterval(-noticeLookback)
        let newlyCompleted = recentlyPrepared.filter { $0.completedAt > boundary }
        guard let newest = newlyCompleted.first else { return nil }
        let message: String
        if newlyCompleted.count == 1 {
            message = "Ready offline: \(newest.title)."
        } else {
            message = "Ready offline: \(newest.title) and \(newlyCompleted.count - 1) more. Review them in Preparing Audio."
        }
        return PreparedAudioNotice(message: message, newestCompletedAt: newest.completedAt)
    }
}
