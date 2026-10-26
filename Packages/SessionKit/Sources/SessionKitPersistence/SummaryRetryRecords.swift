import Foundation
import SessionKit

/// What the Summarize / Retry summary controls need from the store (#2508). They are asked for on every render of
/// the playback screen, so the app loads this once per state of the session, off the main thread, through
/// `StoreReader` and `SummaryRecordsCache`.
public struct SummaryRetryRecords: Sendable, Equatable {
    public var jobs: [AIJob]
    /// Only filled when a summary job is retryable; most sessions have none, so they cost one query.
    public var turns: [ConversationTurn]
    public var interjections: [Interjection]

    public static func load(store: SQLiteSessionStore, sessionId: String, itemId: String) throws -> SummaryRetryRecords {
        let jobs = try store.loadAIJobs(sessionId: sessionId)
        guard !retryableSummaryJobs(in: jobs, itemId: itemId).isEmpty else {
            return SummaryRetryRecords(jobs: jobs, turns: [], interjections: [])
        }
        return SummaryRetryRecords(
            jobs: jobs,
            turns: try store.loadTurns(sessionId: sessionId),
            interjections: try store.loadInterjections(sessionId: sessionId))
    }

    public static func retryableSummaryJobs(in jobs: [AIJob], itemId: String) -> [AIJob] {
        jobs.filter { $0.kind == "interjection_summary" && $0.status == "retryable" && $0.itemId == itemId }
    }

    /// The newest job of `kind` that is waiting to run.
    public static func latestPending(in jobs: [AIJob], kind: String) -> AIJob? {
        jobs.last { $0.kind == kind && ($0.status == "pending" || $0.status == "deferred") }
    }
}

/// Holds the latest `SummaryRetryRecords` for the session state a View is showing (#2508). A render asks with a key
/// built from the state that can change the answer; a new key starts one background load and, until it arrives,
/// the previous answer stays on screen, so a button never flickers. The key is the invalidation.
@MainActor
public final class SummaryRecordsCache {
    private var loadedKey: String?
    private var loadingKey: String?
    private var records: SummaryRetryRecords?
    public private(set) var loads = 0

    public init() {}

    public func current(
        key: String,
        load: @escaping @Sendable () async -> SummaryRetryRecords?,
        onLoaded: @escaping @MainActor () -> Void
    ) -> SummaryRetryRecords? {
        guard key != loadedKey, key != loadingKey else { return records }
        loadingKey = key
        Task { @MainActor [weak self] in
            let loaded = await load()
            // A newer key started while this one was reading: its answer wins.
            guard let self, self.loadingKey == key else { return }
            self.loadingKey = nil
            self.loadedKey = key
            self.records = loaded
            self.loads += 1
            onLoaded()
        }
        return records
    }

    /// Forces the next `current` to read again, keeping the old answer on screen meanwhile.
    public func invalidate() {
        loadedKey = nil
        loadingKey = nil
    }
}
