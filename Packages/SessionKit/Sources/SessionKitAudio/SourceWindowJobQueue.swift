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
    /// A job that runs longer than this is cancelled. A transcription that never returns (no network for a speech
    /// asset, a stalled export) would otherwise hold one of the two slots until the app restarts, and two of them
    /// would stop source context for every Margin. The slot is freed only when the job has actually returned, so no
    /// more than `maxConcurrent` jobs ever run at once: a job that ignores cancellation keeps its slot, as it did
    /// before the limit. The limit is wall-clock time, so it also runs while the app is suspended.
    public static let defaultJobTimeout: Duration = .seconds(600)

    private struct Pending {
        let id: String
        let anchorMediaTimeMs: Int
        let playhead: @MainActor () -> Int?
        let sequence: Int
        let work: @MainActor () async -> Void
    }

    private struct Running {
        let work: Task<Void, Never>
        let timeout: Task<Void, Never>
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
    /// How many jobs were cancelled for running longer than `jobTimeout`.
    public private(set) var timedOutCount = 0

    public init(maxConcurrent: Int = SourceWindowJobQueue.defaultMaxConcurrent,
                jobTimeout: Duration = SourceWindowJobQueue.defaultJobTimeout) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.jobTimeout = jobTimeout
    }

    public var runningCount: Int { running.count }
    public var queuedCount: Int { pending.count }

    /// Queues `work` under `id`. `playhead` is asked for where the listener is in this job's episode each time the
    /// queue picks its next job, so a seek while jobs wait is followed; nil means the episode isn't playing, and the
    /// job is then ordered as if the playhead were at the start. A job whose id is already waiting is ignored, so a
    /// second download callback can't double the work. An id that is running may be queued again: the caller's own
    /// pending flag is what stops a duplicate, and dropping a request that arrives just as its job ends would leave
    /// that flag set for good. Returns whether the job was accepted.
    @discardableResult
    public func enqueue(
        id: String,
        anchorMediaTimeMs: Int,
        playhead: @escaping @MainActor () -> Int?,
        work: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard !queuedIds.contains(id) else { return false }
        queuedIds.insert(id)
        pending.append(Pending(
            id: id,
            anchorMediaTimeMs: anchorMediaTimeMs,
            playhead: playhead,
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
        let distances = pending.map { abs($0.anchorMediaTimeMs - ($0.playhead() ?? 0)) }
        guard let index = pending.indices.min(by: { lhs, rhs in
            distances[lhs] != distances[rhs] ? distances[lhs] < distances[rhs] : pending[lhs].sequence < pending[rhs].sequence
        }) else { return nil }
        let job = pending.remove(at: index)
        queuedIds.remove(job.id)
        return job
    }

    private func start(_ job: Pending) {
        let key = job.sequence
        let work = job.work
        let timeout = jobTimeout
        let workTask = Task { [weak self] in
            await work()
            self?.finish(key)
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.expire(key)
        }
        running[key] = Running(work: workTask, timeout: timeoutTask)
        peakRunning = max(peakRunning, running.count)
    }

    private func finish(_ key: Int) {
        guard let job = running.removeValue(forKey: key) else { return }
        job.timeout.cancel()
        startAvailable()
    }

    private func expire(_ key: Int) {
        // Only asks the job to stop. The slot stays taken until the job returns and `finish` frees it, so a job that
        // ignores the request can't be joined by a third.
        guard let job = running[key] else { return }
        timedOutCount += 1
        job.work.cancel()
    }
}
