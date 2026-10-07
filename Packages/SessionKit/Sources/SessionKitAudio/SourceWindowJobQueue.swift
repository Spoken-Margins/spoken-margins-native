import Foundation

/// Runs source-window jobs (export, transcribe, fingerprint) a few at a time, nearest the playhead first (#871).
///
/// When a download finished, the app started one job for every Margin on the episode at once. A two-hour episode
/// with 22 shared Margins stalled the Mac and, with the placement pass and the full transcript running at the same
/// moment, helped get the phone's app killed (#873). Each job is cheap alone, so the cure is to bound how many run.
public actor SourceWindowJobQueue {
    public static let defaultMaxConcurrent = 2

    private struct Pending {
        let id: String
        let anchorMediaTimeMs: Int
        let sequence: Int
        let work: @Sendable () async -> Void
    }

    private let maxConcurrent: Int
    private var pending: [Pending] = []
    private var queuedIds: Set<String> = []
    private var playheadMediaTimeMs: Int = 0
    private var nextSequence = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var runningCount = 0
    /// The most jobs that ever ran at once. Tests read it; nothing else should.
    public private(set) var peakRunning = 0

    public init(maxConcurrent: Int = SourceWindowJobQueue.defaultMaxConcurrent) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public var queuedCount: Int { pending.count }

    /// Queues `work` under `id`. A job whose id is already waiting is ignored, so a second download callback
    /// can't double the work. An id that is running may be queued again: the caller's own pending flag is what
    /// stops a duplicate, and dropping a request that arrives just as its job ends would leave that flag set for
    /// good. Returns whether the job was accepted.
    @discardableResult
    public func enqueue(
        id: String,
        anchorMediaTimeMs: Int,
        playheadMediaTimeMs: Int?,
        work: @escaping @Sendable () async -> Void
    ) -> Bool {
        if let playheadMediaTimeMs { self.playheadMediaTimeMs = playheadMediaTimeMs }
        guard !queuedIds.contains(id) else { return false }
        queuedIds.insert(id)
        pending.append(Pending(id: id, anchorMediaTimeMs: anchorMediaTimeMs, sequence: nextSequence, work: work))
        nextSequence += 1
        startAvailable()
        return true
    }

    /// Returns once nothing is queued or running.
    public func waitUntilIdle() async {
        if pending.isEmpty && runningCount == 0 { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func startAvailable() {
        while runningCount < maxConcurrent, let job = takeNearest() {
            runningCount += 1
            peakRunning = max(peakRunning, runningCount)
            Task { [work = job.work] in
                await work()
                self.finished()
            }
        }
    }

    private func takeNearest() -> Pending? {
        let playhead = playheadMediaTimeMs
        guard let index = pending.indices.min(by: { lhs, rhs in
            let l = abs(pending[lhs].anchorMediaTimeMs - playhead)
            let r = abs(pending[rhs].anchorMediaTimeMs - playhead)
            return l != r ? l < r : pending[lhs].sequence < pending[rhs].sequence
        }) else { return nil }
        let job = pending.remove(at: index)
        queuedIds.remove(job.id)
        return job
    }

    private func finished() {
        runningCount -= 1
        startAvailable()
        if pending.isEmpty && runningCount == 0 {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }
}
