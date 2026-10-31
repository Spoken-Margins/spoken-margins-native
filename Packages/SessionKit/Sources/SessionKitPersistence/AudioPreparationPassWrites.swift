import Foundation
import SessionKit

/// The store writes of one Library audio-preparation pass, for a caller off the main actor (#2509, fix class
/// `write-behind`). The pass renders a chunk, then records it: that record, the job deletes around it and the failure
/// marks are small, but they ran on the main thread between two awaits and could wait on a busy write lock.
///
/// Callers run them through `StoreReader.readInOrder(AudioPreparationQueueEdits.orderKey)`, so a pass's write lines up
/// with the queue's Move, Prioritize, Skip and Clear. Each one reads the job again inside its own transaction, so a
/// priority the listener set while the chunk rendered is never written back stale.
public enum AudioPreparationPassWrites {
    /// What a recorded chunk does to its job.
    public enum JobChange: Equatable, Sendable {
        case save(AudioPreparationJob)
        case delete(id: String)
    }

    /// The decision for one committed chunk: what to do with the job, whether the finished audio now needs
    /// assembling, and a note for the pass to put in Diagnostics.
    public struct Decision: Equatable, Sendable {
        public var change: JobChange
        public var needsAssembly: Bool
        public var note: String?
        public init(change: JobChange, needsAssembly: Bool, note: String? = nil) {
            self.change = change
            self.needsAssembly = needsAssembly
            self.note = note
        }
    }

    /// Removes a job the pass found stale, listened-to, or fully done.
    public static func discardJob(id: String, in store: SQLiteSessionStore) throws {
        try store.deleteAudioPreparationJob(id: id)
    }

    /// The voice changed since the manifest was made: the manifest is saved as it is (the caller marks it
    /// `needsRepreparation`) and the job goes, in one transaction. False when the preparation no longer belongs to its
    /// item, in which case nothing was written.
    public static func retireManifest(
        _ manifest: PreparedAudioManifest, discardingJobId jobId: String, in store: SQLiteSessionStore
    ) throws -> Bool {
        let applied: Bool? = try PreparedAudioEnqueue.withCurrentManifest(manifest, repository: store) { _, _ in
            try store.savePreparedAudioManifest(manifest)
            try store.deleteAudioPreparationJob(id: jobId)
            return true
        }
        return applied != nil
    }

    /// Records a committed chunk on its job. The job is read again inside the transaction (`fallback` stands in when it
    /// is gone), `decide` says what to do with it, and the change is applied. Nil when the preparation no longer
    /// belongs to its item; nothing was written then.
    public static func recordChunk(
        in manifest: PreparedAudioManifest, jobId: String, fallback: AudioPreparationJob,
        decide: @Sendable (AudioPreparationJob) -> Decision, store: SQLiteSessionStore
    ) throws -> Decision? {
        try PreparedAudioEnqueue.withCurrentManifest(manifest, repository: store) { _, _ in
            let job = try store.loadAudioPreparationJob(id: jobId) ?? fallback
            let decision = decide(job)
            switch decision.change {
            case .save(let job): try store.saveAudioPreparationJob(job)
            case .delete(let id): try store.deleteAudioPreparationJob(id: id)
            }
            return decision
        }
    }

    /// Notes why the pass stopped on a job (an expiry, an error). Only the failure code changes, on the job as it is
    /// now; a job that was since skipped or finished is not brought back. Whether the preparation still belongs to its
    /// item is checked against the manifest the job names.
    public static func markFailure(
        jobId: String, manifestId: String, code: String, in store: SQLiteSessionStore
    ) throws {
        guard let manifest = try store.loadPreparedAudioManifest(id: manifestId) else { return }
        _ = try PreparedAudioEnqueue.withCurrentManifest(manifest, repository: store) { _, _ -> Bool in
            guard var job = try store.loadAudioPreparationJob(id: jobId) else { return false }
            job.lastFailureCode = code
            try store.saveAudioPreparationJob(job)
            return true
        }
    }
}

extension AudioPreparationQueueEdits {
    /// Records that background time ran out on every remaining explicit request (`OfflinePreparationRecovery`), in one
    /// transaction. Returns how many jobs changed.
    @discardableResult
    public static func markInterrupted(
        requests: Set<OfflinePreparationRun.RequestKey>, in store: SQLiteSessionStore
    ) throws -> Int {
        try store.withSessionTransaction {
            let interrupted = OfflinePreparationRecovery.interruptedJobs(try store.loadAudioPreparationJobs(), requests: requests)
            for job in interrupted { try store.saveAudioPreparationJob(job) }
            return interrupted.count
        }
    }
}
