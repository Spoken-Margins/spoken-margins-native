import Foundation

/// Library audio preparation (#281): one item at a time, the playing item first.
public enum LibraryAudioPreparationQueue {
    /// The order jobs are prepared in: the listener's own priority, then the playing
    /// item, then opening buffers, explicit requests and demand windows, newest first.
    /// The order doesn't depend on progress, so one item runs to its target before the
    /// next starts.
    public static func precedes(_ lhs: AudioPreparationJob, _ rhs: AudioPreparationJob, activeItemId: String?) -> Bool {
        if lhs.userPriority != rhs.userPriority {
            return (lhs.userPriority ?? .max) < (rhs.userPriority ?? .max)
        }
        if let activeItemId, (lhs.itemId == activeItemId) != (rhs.itemId == activeItemId) {
            return lhs.itemId == activeItemId
        }
        let lhsIsOpeningBuffer = lhs.policy == .demandWindow && lhs.maximumChunkCount != nil
        let rhsIsOpeningBuffer = rhs.policy == .demandWindow && rhs.maximumChunkCount != nil
        if lhsIsOpeningBuffer != rhsIsOpeningBuffer {
            return lhsIsOpeningBuffer
        }
        if (lhs.policy == .explicit) != (rhs.policy == .explicit) {
            return lhs.policy == .explicit
        }
        if lhs.policy != rhs.policy {
            if lhs.policy == .demandWindow { return true }
            if rhs.policy == .demandWindow { return false }
        }
        if lhs.requestedAt != rhs.requestedAt {
            return lhs.requestedAt > rhs.requestedAt
        }
        return lhs.id < rhs.id
    }
}

/// Which of the app's two preparation passes is asking for work (#281).
public enum LibraryAudioPreparationCaller: Sendable {
    /// The in-app loop. It prepares only what the listener is waiting for: explicit
    /// requests and opening buffers, never While Charging work.
    case foreground
    /// The background processing task, which runs on power and prepares everything.
    case background
}

/// Which Library item the preparation passes are working on, so the two passes stay on
/// one item until its target is done (#281, #534).
///
/// Each pass prepares one part. If the foreground loop picked its own job while the
/// background task worked on a While Charging job the loop may not touch, the two took
/// turns A, B, A, B. So while the background task is preparing, the foreground loop
/// takes only the job the background task would take next, and otherwise waits. When
/// the background task stops, the foreground loop picks its own work again, so an
/// explicit request never waits on a background task that isn't running.
public struct LibraryAudioPreparationTurns: Sendable {
    /// The item a pass is working on; its Library row is the one that shows progress.
    public var preparingItemId: String?
    /// True from the background task's first pick until it stops or has nothing left.
    public private(set) var backgroundIsPreparing = false
    /// True when the foreground loop last stopped to wait for the background task.
    public private(set) var foregroundIsWaiting = false

    /// The foreground loop stopped to wait, and the background task has stopped since:
    /// start the loop again, or an explicit request waits for an unrelated trigger.
    public var foregroundShouldRestart: Bool { foregroundIsWaiting && !backgroundIsPreparing }

    public init() {}

    /// Work the foreground loop may do without power: explicit requests and opening buffers.
    public static func isForegroundDemand(_ job: AudioPreparationJob) -> Bool {
        job.policy == .explicit || (job.policy == .demandWindow && job.maximumChunkCount != nil)
    }

    /// The jobs `caller` may prepare, in order, ignoring cancelled ones.
    public static func eligible(_ jobs: [AudioPreparationJob], for caller: LibraryAudioPreparationCaller) -> [AudioPreparationJob] {
        jobs.filter { !$0.isCancelled && (caller == .background || isForegroundDemand($0)) }
    }

    /// The job `caller` prepares next, or nil when it has nothing to do or must wait for
    /// the background task. Records the chosen item as the one being prepared.
    public mutating func select(
        _ jobs: [AudioPreparationJob],
        activeItemId: String?,
        for caller: LibraryAudioPreparationCaller
    ) -> AudioPreparationJob? {
        let ordered = jobs.filter { !$0.isCancelled }
            .sorted { LibraryAudioPreparationQueue.precedes($0, $1, activeItemId: activeItemId) }
        switch caller {
        case .background:
            let chosen = ordered.first
            backgroundIsPreparing = chosen != nil
            preparingItemId = chosen?.itemId
            return chosen
        case .foreground where backgroundIsPreparing:
            // Share the background task's item, or wait for it.
            let chosen = ordered.first.flatMap { Self.isForegroundDemand($0) ? $0 : nil }
            foregroundIsWaiting = chosen == nil
            if let chosen { preparingItemId = chosen.itemId }
            return chosen
        case .foreground:
            let chosen = ordered.first(where: Self.isForegroundDemand)
            foregroundIsWaiting = false
            preparingItemId = chosen?.itemId
            return chosen
        }
    }

    /// `caller` couldn't run at all: Low Power Mode, heat, unaccepted terms or no voice (#647).
    /// A foreground loop that was waiting for the background task isn't waiting any more, so it
    /// must not restart itself until one of those changes: the app's own triggers (coming to the
    /// foreground, Prepare Now, playback changes) start it again.
    public mutating func blocked(_ caller: LibraryAudioPreparationCaller) {
        if caller == .foreground { foregroundIsWaiting = false }
        stopped(caller)
    }

    /// `caller` stopped: it finished, was cancelled, expired, or is waiting. The item it was
    /// preparing stops showing progress, unless the other pass is still working on it.
    public mutating func stopped(_ caller: LibraryAudioPreparationCaller) {
        switch caller {
        case .background:
            guard backgroundIsPreparing else { return }
            backgroundIsPreparing = false
            preparingItemId = nil
        case .foreground:
            if !backgroundIsPreparing { preparingItemId = nil }
        }
    }

    /// The foreground loop ended. Returns whether it should start again because it had
    /// stopped to wait for a background task that has since stopped. The resume is used
    /// up here: a replacement pass that stops before it selects (Low Power Mode, heat)
    /// must not restart the loop again and again (Codex audit on #644).
    public mutating func foregroundLoopEnded() -> Bool {
        stopped(.foreground)
        guard foregroundShouldRestart else { return false }
        foregroundIsWaiting = false
        return true
    }
}

/// Lets one piece of work run at a time; the rest wait their turn, first come first
/// served. The app's two preparation passes (the foreground loop and the background
/// task) share one, so two Library items never render at once (#281).
public actor SerialWorkGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` on the main actor when it's this caller's turn, then hands the turn on.
    public nonisolated func run<T: Sendable>(_ body: @MainActor @Sendable () async -> T) async -> T {
        await acquire()
        let result = await body()
        await release()
        return result
    }
}
