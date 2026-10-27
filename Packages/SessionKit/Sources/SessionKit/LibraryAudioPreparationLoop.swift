import Foundation

/// What the foreground preparation loop asks of the model that owns it (#995). The loop never holds
/// its host while idle; it holds it for the length of one run, as the model's own task did before.
@MainActor
public protocol LibraryAudioPreparationHost: AnyObject {
    /// Read live at every restart decision, never captured once.
    var playbackAllowsLibraryAudioPreparation: Bool { get }
    /// Asks iOS to keep the app running for a long run; called on every start request, even while a run is going (#905).
    func requestContinuedAudioPreparationIfNeeded()
    /// Runs the passes until they have no more work, waiting out a heat pause or a memory backoff in between.
    func runForegroundAudioPreparationPasses() async
    /// A run ended and nothing newer owns the loop: refresh the rows that show preparation progress.
    func foregroundAudioPreparationLoopDidEnd()
}

/// The foreground audio preparation loop: its task, the generation that says which run still owns it,
/// the two passes' turns, and the gate that keeps two Library items from rendering at once (#281, #534, #995).
///
/// Two ways to stop a run, on purpose:
/// - `cancelOnly()` cancels the task and leaves it in place. The run's own finalizer then ends it and,
///   when playback allows, starts a fresh one. Snapshot changes, memory warnings and `deinit` use it.
/// - `stopAndInvalidate()` cancels, bumps the generation and drops the task, so the old run can no longer
///   restart anything or finalize a replacement. Engine rebuilds, clearing the queue and the continued-processing
///   task's expiry use it.
@MainActor
public final class LibraryAudioPreparationLoop {
    /// One Library item renders at a time; the foreground loop and the background task share it (#281).
    public let renderGate = SerialWorkGate()
    /// Whether the Library may render next to the player, and the listener-engaged flag that goes with it (#2694).
    public var renderPolicy = LibraryAudioRenderPolicy()
    /// Which item the two passes are on (#281, #534).
    public var turns = LibraryAudioPreparationTurns()
    /// Bumped by every start and every invalidation. A run that finds a different number on its way out is stale.
    public private(set) var generation = 0

    private let holder = TaskHolder()

    public init() {}

    /// True from `start` until the run's finalizer (or an invalidation) drops the task.
    public nonisolated var isRunning: Bool { holder.hasTask }

    /// Callable from the model's `deinit`, which is not on the main actor.
    public nonisolated func cancelOnly() {
        holder.cancel()
    }

    public func stopAndInvalidate() {
        holder.cancelAndClear()
        generation += 1
    }

    /// Starts a run unless one is going. The continued-processing request comes first on purpose:
    /// a run may already be going when the listener asks again (#905).
    public func start(host: any LibraryAudioPreparationHost) {
        // Before the "Preparing audio for offline listening" card: a run that stops at once only ends as a failed card (#2694).
        guard host.playbackAllowsLibraryAudioPreparation else { return }
        host.requestContinuedAudioPreparationIfNeeded()
        guard !holder.hasTask else { return }
        generation += 1
        let started = generation
        holder.install(Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            await host.runForegroundAudioPreparationPasses()
            let ownsLoop = self.generation == started
            if ownsLoop || !self.holder.hasTask {
                // Also when cancelled between passes: its item stops showing progress (#281).
                let resume = ownsLoop ? self.turns.foregroundLoopEnded() : false
                if !ownsLoop { self.turns.stopped(.foreground) }
                if ownsLoop { self.holder.clear() }
                if ownsLoop, Task.isCancelled || resume, host.playbackAllowsLibraryAudioPreparation {
                    self.start(host: host)
                }
                host.foregroundAudioPreparationLoopDidEnd()
            }
        })
    }
}

/// The run's task behind a lock, so `deinit` can cancel it without hopping to the main actor.
/// (Swift's isolated `deinit` is avoided on purpose: see `ImportedMarginRemoteControls`.)
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var hasTask: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil
    }

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func cancelAndClear() {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    func clear() {
        lock.lock()
        task = nil
        lock.unlock()
    }
}
