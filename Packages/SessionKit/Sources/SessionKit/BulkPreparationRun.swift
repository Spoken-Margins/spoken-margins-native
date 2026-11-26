import Foundation

/// How one item of a bulk run came back (#969, #4647).
public enum BulkPreparationOutcome: Equatable, Sendable {
    /// It got the best result.
    case prepared
    /// It finished, with a fallback.
    case fellBack
    /// It left the run before it finished (switched out, or the sender picked a version that needs no work). Neither
    /// finished nor failed: the host takes it out of the run's total.
    case skipped
    /// What it was doing went stale because the item changed under it (a hand edit during its render). The run puts it
    /// back at the end of its queue and reports nothing, so the total and the counts don't move.
    case requeued
}

/// What the "Prepare All Included" loop asks of the model that owns it (#969). The run never holds its
/// host while idle; it holds it for the length of one run, as the model's own task did before.
@MainActor
public protocol BulkPreparationHost: AnyObject {
    /// Prepares one item and says how it came back.
    /// The work checks `ticket` after every await and drops what it was doing when the ticket is no longer live.
    func prepareForBulkRun(itemID: String, ticket: BulkPreparationTicket) async -> BulkPreparationOutcome
    /// One item came back while the run still owned the loop, or was skipped before its turn; counted after the stale
    /// check, so a late result is never counted. Never called with `.requeued`.
    func bulkRunDidFinishOne(_ outcome: BulkPreparationOutcome)
    /// Every item came back and nothing newer owns the run.
    func bulkRunDidComplete()
    /// An item joined a live run (`append`), so the run's total grows by one (#4647).
    func bulkRunDidAppend(itemID: String)
    /// The items still to do or being done changed: the one in progress plus the queue (#4647). Empty once the run ends.
    func bulkRunPendingDidChange(_ pending: Set<String>)
}

public extension BulkPreparationHost {
    func bulkRunDidAppend(itemID: String) {}
    func bulkRunPendingDidChange(_ pending: Set<String>) {}
}

/// The one rule for "does this late result still count" (#969). Three guards used to be written out by hand
/// at every await: the task's own cancellation, the run counter, and (per draft, kept by the host) the render counter.
/// The first two live here.
@MainActor
public struct BulkPreparationTicket {
    public let generation: Int
    private let run: BulkPreparationRun

    fileprivate init(generation: Int, run: BulkPreparationRun) {
        self.generation = generation
        self.run = run
    }

    /// The run this ticket belongs to was neither cancelled nor replaced. A result that finds this false is
    /// stale: it must not touch the drafts, and a cleaned copy it wrote is the host's to delete.
    public var isLive: Bool { !Task.isCancelled && run.generation == generation }

    /// No newer run or cancel has taken over since this one started, whatever happened to the task itself.
    /// For bookkeeping that is still right when only the task was cancelled (its host went away) and for
    /// nothing else; use `isLive` before writing a result.
    public var isCurrent: Bool { run.generation == generation }
}

/// The bulk run: its task, the counter that says which run still owns it, and the loop that goes one item
/// at a time (#969). Items go strictly one after another; each item's own work is the host's.
///
/// The loop reads a queue that can change while it runs (#4647): `append` adds an item to a live run, `skip` takes a
/// queued one out, and an item that comes back `.requeued` goes to the end. Every way the loop ends leaves the queue
/// empty.
///
/// Two ways to stop a run, on purpose:
/// - `invalidateAndCancel()` bumps the counter, cancels the task and drops it. The run's tickets turn stale at once,
///   so a result still in flight is thrown away when it lands.
/// - `cancelOnly()` cancels the task and nothing else. The model's `deinit` uses it: it is not on the main actor,
///   and there is no run left to replace.
@MainActor
public final class BulkPreparationRun {
    /// Bumped by every start and every invalidation. A result that finds a different number is stale.
    public private(set) var generation = 0

    private let holder = BulkRunTaskHolder()
    /// The items still to do, in order. Owned by the live run only.
    private var queue: [String] = []
    /// The item whose work is out now.
    private var inProgress: String?
    /// The live run's host, to tell it about `append` and `skip`. Held weakly, as the run's task holds it.
    private weak var activeHost: (any BulkPreparationHost)?

    public init() {}

    /// True from `start` until the run finishes or is invalidated.
    public nonisolated var hasTask: Bool { holder.hasTask }

    /// The item in progress and every queued one. Empty when no run is live.
    public var pending: Set<String> {
        var ids = Set(queue)
        if let inProgress { ids.insert(inProgress) }
        return ids
    }

    /// Callable from the model's `deinit`, which is not on the main actor.
    public nonisolated func cancelOnly() {
        holder.cancel()
    }

    public func invalidateAndCancel() {
        generation += 1
        holder.cancelAndClear()
        clearQueue()
    }

    /// Adds an item to the end of a live run's queue. Returns `false` when no run is live, so the caller starts a run
    /// of one. An item already queued or in progress is not added twice (and `true` is returned).
    @discardableResult
    public func append(id: String) -> Bool {
        guard holder.hasTask else { return false }
        guard !pending.contains(id) else { return true }
        queue.append(id)
        activeHost?.bulkRunDidAppend(itemID: id)
        activeHost?.bulkRunPendingDidChange(pending)
        return true
    }

    /// Takes a queued item out before its turn; the host is told it was `.skipped`. The item in progress is not
    /// touched: its own work checks whether it still counts. Returns whether it was queued.
    @discardableResult
    public func skip(id: String) -> Bool {
        guard let index = queue.firstIndex(of: id) else { return false }
        queue.remove(at: index)
        activeHost?.bulkRunDidFinishOne(.skipped)
        activeHost?.bulkRunPendingDidChange(pending)
        return true
    }

    /// Starts a run over `ids`, replacing any run that is going (its tickets turn stale). The host is held for
    /// the length of the run only, weakly until the run starts.
    public func start(ids: [String], host: any BulkPreparationHost) {
        generation += 1
        let started = generation
        let ticket = BulkPreparationTicket(generation: started, run: self)
        holder.cancelAndClear()
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        queue = unique
        inProgress = nil
        activeHost = host
        host.bulkRunPendingDidChange(pending)
        holder.install(Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            while !self.queue.isEmpty {
                guard ticket.isLive else { return }
                let id = self.queue.removeFirst()
                self.inProgress = id
                let outcome = await host.prepareForBulkRun(itemID: id, ticket: ticket)
                guard ticket.isLive else { return }
                self.inProgress = nil
                if outcome == .requeued {
                    self.queue.append(id)
                } else {
                    host.bulkRunDidFinishOne(outcome)
                }
                host.bulkRunPendingDidChange(self.pending)
            }
            guard self.generation == started else { return }
            self.clearQueue()
            self.holder.clear()
            host.bulkRunDidComplete()
        })
    }

    private func clearQueue() {
        let hadPending = !pending.isEmpty
        queue = []
        inProgress = nil
        if hadPending { activeHost?.bulkRunPendingDidChange([]) }
        activeHost = nil
    }
}

/// The run's task behind a lock, so `deinit` can cancel it without hopping to the main actor.
/// (Swift's isolated `deinit` is avoided on purpose, as in `LibraryAudioPreparationLoop`.)
private final class BulkRunTaskHolder: @unchecked Sendable {
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
