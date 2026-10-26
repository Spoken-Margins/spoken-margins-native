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
    private var loading: (key: String, task: Task<SummaryRetryRecords?, Never>)?
    private var records: SummaryRetryRecords?
    public private(set) var loads = 0

    public init() {}

    public func current(
        key: String,
        load: @escaping @Sendable () async -> SummaryRetryRecords?,
        onLoaded: @escaping @MainActor () -> Void
    ) -> SummaryRetryRecords? {
        guard key != loadedKey, key != loading?.key else { return records }
        start(key: key, load: load, onLoaded: onLoaded)
        return records
    }

    /// True when the answer `current` gives was read for `key`, not kept from an older state.
    public func isSettled(key: String) -> Bool { key == loadedKey }

    /// The answer for `key` itself, read now (or joining the read already running for it). A decision such as a
    /// Summarize tap uses this, so it never acts on the previous state's answer (#2747).
    public func settle(
        key: String,
        load: @escaping @Sendable () async -> SummaryRetryRecords?,
        onLoaded: @escaping @MainActor () -> Void
    ) async -> SummaryRetryRecords? {
        if key == loadedKey { return records }
        if let loading, loading.key == key { return await loading.task.value }
        return await start(key: key, load: load, onLoaded: onLoaded).value
    }

    @discardableResult
    private func start(
        key: String,
        load: @escaping @Sendable () async -> SummaryRetryRecords?,
        onLoaded: @escaping @MainActor () -> Void
    ) -> Task<SummaryRetryRecords?, Never> {
        let task = Task { @MainActor [weak self] () -> SummaryRetryRecords? in
            let loaded = await load()
            // A newer key started while this one was reading: its answer wins on screen.
            guard let self, self.loading?.key == key else { return loaded }
            self.loading = nil
            self.loadedKey = key
            self.records = loaded
            self.loads += 1
            onLoaded()
            return loaded
        }
        loading = (key, task)
        return task
    }

    /// Forces the next `current` to read again, keeping the old answer on screen meanwhile.
    public func invalidate() {
        loadedKey = nil
        loading = nil
    }
}
