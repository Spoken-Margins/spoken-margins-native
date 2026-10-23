import Foundation

/// Serializes eligibility and enqueue writes with extraction upgrades.
public protocol SessionRepositoryTransaction: SessionRepository {
    func withSessionTransaction<T>(_ operation: () throws -> T) throws -> T
}

public enum PreparedAudioEnqueue {
    public enum Rejection: Error, Equatable { case staleSource }

    public static func withValidatedSource<T>(
        itemId: String, sourceText: String, repository: any SessionRepository,
        operation: () throws -> T
    ) throws -> T {
        guard let store = repository as? any SessionRepositoryTransaction else {
            throw SessionKitError.persistenceFailed("preparation_requires_transaction")
        }
        return try store.withSessionTransaction {
            let item = try repository.loadItem(id: itemId)
            guard item.deletedAt == nil, try preparedText(item: item, repository: repository) == sourceText else {
                throw Rejection.staleSource
            }
            return try operation()
        }
    }

    /// Whether finished assembly may mark a manifest ready. A Stop, a failure or a retirement
    /// (the voice changed, so the old manifest needs repreparing) that landed while the audio
    /// was being assembled must win; the finished audio is dropped, not saved (#2134).
    public static func mayComplete(_ state: PreparedAudioState) -> Bool {
        switch state {
        case .preparing, .pausedForThermal, .readyOffline: return true
        case .notPrepared, .needsRepreparation, .stopped, .failed: return false
        }
    }

    /// Runs a record update only while this preparation still belongs to the item.
    public static func withCurrentManifest<T>(
        _ candidate: PreparedAudioManifest, repository: any SessionRepository,
        operation: (PreparedAudioManifest, Item) throws -> T
    ) throws -> T? {
        guard let store = repository as? any SessionRepositoryTransaction else {
            throw SessionKitError.persistenceFailed("preparation_requires_transaction")
        }
        return try store.withSessionTransaction {
            guard let current = try repository.loadPreparedAudioManifest(id: candidate.id),
                  current.signature == candidate.signature, current.articleIdentity == candidate.articleIdentity else { return nil }
            let item: Item
            do { item = try repository.loadItem(id: candidate.itemId) }
            catch SessionKitError.missingFixture { return nil }
            guard let text = try preparedText(item: item, repository: repository), item.deletedAt == nil,
                  candidate.articleIdentity.map({ $0 == NarrationChunkPlanner.identity(ofArticle: text) }) ?? true else { return nil }
            return try operation(current, item)
        }
    }

    /// Read directly inside the transaction; a cached no-document projection can be stale after re-import.
    public static func preparedText(item: Item, repository: any SessionRepository) throws -> String? {
        let document = try (repository as? any StructuredDocumentRepository)?.loadStructuredDocument(itemId: item.id)
        return PreparedSpeechText(item: item, document: document)?.text
    }

    /// Identical canonical text can adopt a document while paused. Retire preparation whose
    /// speech or offsets change, without moving the held item's text, map or listening positions.
    static func saveStructuredDocument(
        _ document: StructuredDocument, itemId: String,
        repository: any (SessionRepository & StructuredDocumentRepository)
    ) throws {
        let save = {
            let item = try repository.loadItem(id: itemId)
            let old = try repository.loadStructuredDocument(itemId: itemId)
            if PreparedSpeechText(item: item, document: old) != PreparedSpeechText(item: item, document: document) {
                for manifest in try repository.loadPreparedAudioManifests(itemId: itemId) {
                    try repository.deletePreparedAudioManifest(id: manifest.id)
                }
                for job in try repository.loadAudioPreparationJobs() where job.itemId == itemId {
                    try repository.deleteAudioPreparationJob(id: job.id)
                }
            }
            try repository.saveStructuredDocument(document, itemId: itemId)
        }
        if let store = repository as? any SessionRepositoryTransaction { try store.withSessionTransaction(save) }
        else { try save() }
    }

    public enum Request: Sendable {
        case startup(maximumChunkCount: Int, requestedAt: Date?)
        case explicit
        case automatic(requestedAt: Date?)
    }

    /// A caller may have suspended after begin. Recheck eligibility and the live
    /// manifest before changing policy, so it cannot resurrect a retired job.
    @discardableResult
    public static func configureJob(
        manifest: PreparedAudioManifest, sourceText: String,
        repository: any SessionRepository, request: Request
    ) throws -> AudioPreparationJob? {
        try withValidatedSource(itemId: manifest.itemId, sourceText: sourceText, repository: repository) {
            guard let current = try repository.loadPreparedAudioManifest(id: manifest.id),
                  current.signature == manifest.signature, current.articleIdentity == manifest.articleIdentity else {
                throw Rejection.staleSource
            }
            guard current.state != .readyOffline else { return nil }
            let existing = try repository.loadAudioPreparationJobs().first { $0.manifestId == current.id }
            var job = existing ?? AudioPreparationJob(id: "job-\(current.id)", itemId: current.itemId, manifestId: current.id, policy: .demandWindow)
            switch request {
            case .startup(let maximum, let requestedAt):
                guard current.chunks.count < maximum else {
                    if job.policy == .demandWindow, job.maximumChunkCount != nil {
                        try repository.deleteAudioPreparationJob(id: job.id)
                    }
                    return nil
                }
                if job.policy == .demandWindow {
                    job.requestedAt = requestedAt ?? job.requestedAt
                    job.maximumChunkCount = maximum
                }
                job.lastFailureCode = nil
            case .explicit:
                job.policy = .explicit
                job.userPriority = 0
                job.maximumChunkCount = nil
                job.requestedAt = Date()
                job.lastFailureCode = nil
            case .automatic(let requestedAt):
                // Automatic enqueueing never turns the listener's explicit request into charging-only work.
                job = OfflinePreparationRecovery.automaticJob(job, committedChunks: current.chunks.count)
                // New automatic jobs keep the item's order in the Library.
                if existing == nil {
                    job.requestedAt = requestedAt ?? job.requestedAt
                }
            }
            job.isCancelled = false
            try repository.saveAudioPreparationJob(job)
            return job
        }
    }
}
