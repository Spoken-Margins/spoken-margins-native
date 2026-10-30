import Foundation
import SessionKit

/// The audio-preparation queue's edits, for a caller off the main actor (#2507). Each one reads and saves its jobs in
/// one transaction, so a job the render pass saved in between (its `nextChunkIndex`) is never written back stale.
/// Callers run them through `StoreReader.readInOrder(orderKey)`, so two quick taps apply one after the other and a
/// refresh shows the queue as the last edit left it.
public enum AudioPreparationQueueEdits {
    public static let orderKey = "audio-preparation-queue"

    /// Pins `id` ahead of every job that has a priority. False when there is no such job, or it was cancelled.
    public static func prioritize(id: String, in store: SQLiteSessionStore) throws -> Bool {
        try store.withSessionTransaction {
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            guard var selected = jobs.first(where: { $0.id == id }) else { return false }
            // Pin only the selected job. Assigning ranks to the whole queue
            // would demote every future import behind all existing work.
            selected.userPriority = AudioPreparationQueueProjection.nextUserPriority(among: jobs)
            try store.saveAudioPreparationJob(selected)
            return true
        }
    }

    /// Moves `id` one place within its tier (`offset` -1 or 1). False when nothing moved.
    public static func move(id: String, by offset: Int, activeItemId: String?, in store: SQLiteSessionStore) throws -> Bool {
        try store.withSessionTransaction {
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            guard let reordered = AudioPreparationQueueProjection.reorderedTier(
                of: jobs, moving: id, by: offset, activeItemId: activeItemId
            ) else { return false }
            for job in reordered { try store.saveAudioPreparationJob(job) }
            return true
        }
    }

    public struct Skipped: Equatable, Sendable {
        public let itemId: String
        public let title: String?
    }

    /// Deletes every job of the item `id` belongs to. Nil when there is no such job.
    public static func skipItem(ofJob id: String, in store: SQLiteSessionStore) throws -> Skipped? {
        let itemId: String? = try store.withSessionTransaction {
            guard let selected = try store.loadAudioPreparationJob(id: id) else { return nil }
            try store.deleteAudioPreparationJobs(ids: try store.loadAudioPreparationJobs(itemId: selected.itemId).map(\.id))
            return selected.itemId
        }
        guard let itemId else { return nil }
        return Skipped(itemId: itemId, title: try? store.loadItemSummary(id: itemId)?.title)
    }

    public struct Cleared: Equatable, Sendable {
        public let count: Int
        public let itemIds: Set<String>
    }

    /// Deletes every job that isn't cancelled.
    public static func clear(in store: SQLiteSessionStore) throws -> Cleared {
        try store.withSessionTransaction {
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            try store.deleteAudioPreparationJobs(ids: jobs.map(\.id))
            return Cleared(count: jobs.count, itemIds: Set(jobs.map(\.itemId)))
        }
    }
}

extension AudioPreparationPresentation {
    /// The queue and the recently prepared list from the store as it is now, with the stale jobs it found deleted.
    public static func readDeletingStaleJobs(from store: SQLiteSessionStore, activeItemId: String?) throws -> Self {
        let presentation = AudioPreparationPresentation(
            items: try store.listItemSummaries(), sessions: try store.loadSessions(),
            manifests: try store.loadPreparedAudioManifestSummaries(), jobs: try store.loadAudioPreparationJobs(),
            activeItemId: activeItemId)
        try store.deleteAudioPreparationJobs(ids: presentation.staleJobIds)
        return presentation
    }
}
