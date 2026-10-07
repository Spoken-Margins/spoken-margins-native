import Foundation

/// Runs source-window jobs (export, transcribe, fingerprint) a few at a time, nearest the playhead first (#871).
///
/// When a download finished, the app started one job for every Margin on the episode at once. A two-hour episode
/// with 22 shared Margins stalled the Mac and, with the placement pass and the full transcript running at the same
/// moment, helped get the phone's app killed (#873). Each job is cheap alone, so the cure is to bound how many run.
///
/// The queue lives on the main actor, like the model that feeds it. Jobs are not started inside `enqueue`: the
/// first start waits for the caller's current run of work to finish, so a loop that queues 22 jobs has queued all of
/// them before the first one is picked. The nearest to the playhead then really does go first.
@MainActor
public final class SourceWindowJobQueue {
    public static let defaultMaxConcurrent = 2
    /// A job that takes longer than this gives up its slot. A transcription that never returns (no network for a
    /// speech asset, a stalled export) would otherwise hold one of the two slots until the app restarts, and two
    /// of them would stop source context for every Margin.
    public static let defaultJobTimeout: Duration = .seconds(300)

    private struct Pending {
        let id: String
        let anchorMediaTimeMs: Int
        let playheadMediaTimeMs: Int
        let sequence: Int
        let work: @MainActor () async -> Void
    }

    private struct Running {
        var work: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }

    private let maxConcurrent: Int
    private let jobTimeout: Duration
    private var pending: [Pending] = []
    private var queuedIds: Set<String> = []
    private var running: [Int: Running] = [:]
    private var nextSequence = 0
    private var startScheduled = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The most jobs that ever ran at once. Tests read it; nothing else should.
    public private(set) var peakRunning = 0
    /// How many jobs gave up their slot after `jobTimeout`.
    public private(set) var timedOutCount = 0

    public init(maxConcurrent: Int = SourceWindowJobQueue.defaultMaxConcurrent,
                jobTimeout: Duration = SourceWindowJobQueue.defaultJobTimeout) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.jobTimeout = jobTimeout
    }

    public var runningCount: Int { running.count }
    public var queuedCount: Int { pending.count }

    /// Queues `work` under `id`. `playheadMediaTimeMs` is where the listener is in the episode this job belongs to,
    /// or nil when it isn't playing (the job is then ordered as if the playhead were at the start). A job whose id is
    /// already waiting is ignored, so a second download callback can't double the work. An id that is running may be
    /// queued again: the caller's own pending flag is what stops a duplicate, and dropping a request that arrives
    /// just as its job ends would leave that flag set for good. Returns whether the job was accepted.
    @discardableResult
    public func enqueue(
        id: String,
        anchorMediaTimeMs: Int,
        playheadMediaTimeMs: Int?,
        work: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard !queuedIds.contains(id) else { return false }
        queuedIds.insert(id)
        pending.append(Pending(
            id: id,
            anchorMediaTimeMs: anchorMediaTimeMs,
            playheadMediaTimeMs: playheadMediaTimeMs ?? 0,
            sequence: nextSequence,
            work: work
        ))
        nextSequence += 1
        scheduleStart()
        return true
    }

    /// Returns once nothing is queued or running.
    public func waitUntilIdle() async {
        if pending.isEmpty && running.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func scheduleStart() {
        guard !startScheduled else { return }
        startScheduled = true
        Task { [weak self] in
            self?.startScheduled = false
            self?.startAvailable()
        }
    }

    private func startAvailable() {
        while running.count < maxConcurrent, let job = takeNearest() { start(job) }
        if pending.isEmpty && running.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    private func takeNearest() -> Pending? {
        guard let index = pending.indices.min(by: { lhs, rhs in
            let l = abs(pending[lhs].anchorMediaTimeMs - pending[lhs].playheadMediaTimeMs)
            let r = abs(pending[rhs].anchorMediaTimeMs - pending[rhs].playheadMediaTimeMs)
            return l != r ? l < r : pending[lhs].sequence < pending[rhs].sequence
        }) else { return nil }
        let job = pending.remove(at: index)
        queuedIds.remove(job.id)
        return job
    }

    private func start(_ job: Pending) {
        let key = job.sequence
        let work = job.work
        let timeout = jobTimeout
        running[key] = Running()
        peakRunning = max(peakRunning, running.count)
        running[key]?.work = Task { [weak self] in
            await work()
            self?.finish(key)
        }
        running[key]?.timeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.expire(key)
        }
    }

    private func finish(_ key: Int) {
        // Nil when the job already timed out and gave up its slot.
        guard let job = running.removeValue(forKey: key) else { return }
        job.timeout?.cancel()
        startAvailable()
    }

    private func expire(_ key: Int) {
        guard let job = running.removeValue(forKey: key) else { return }
        timedOutCount += 1
        // A job that watches for cancellation stops and cleans up. One that doesn't keeps running, but no longer
        // holds a slot.
        job.work?.cancel()
        startAvailable()
    }
}
