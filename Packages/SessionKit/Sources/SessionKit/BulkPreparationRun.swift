import Foundation

/// What the "Prepare All Included" loop asks of the model that owns it (#969). The run never holds its
/// host while idle; it holds it for the length of one run, as the model's own task did before.
@MainActor
public protocol BulkPreparationHost: AnyObject {
    /// Prepares one item. Returns whether it got the best result (`false`: it fell back, or the work went stale).
    /// The work checks `ticket` after every await and drops what it was doing when the ticket is no longer live.
    func prepareForBulkRun(itemID: String, ticket: BulkPreparationTicket) async -> Bool
    /// One item came back while the run still owned the loop; counted after the stale check, so a late result is never counted.
    func bulkRunDidFinishOne(prepared: Bool)
    /// Every item came back and nothing newer owns the run.
    func bulkRunDidComplete()
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

    public init() {}

    /// True from `start` until the run finishes or is invalidated.
    public nonisolated var hasTask: Bool { holder.hasTask }

    /// Callable from the model's `deinit`, which is not on the main actor.
    public nonisolated func cancelOnly() {
        holder.cancel()
    }

    public func invalidateAndCancel() {
        generation += 1
        holder.cancelAndClear()
    }

    /// Starts a run over `ids`, replacing any run that is going (its tickets turn stale). The host is held for
    /// the length of the run only, weakly until the run starts.
    public func start(ids: [String], host: any BulkPreparationHost) {
        generation += 1
        let started = generation
        let ticket = BulkPreparationTicket(generation: started, run: self)
        holder.cancelAndClear()
        holder.install(Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            for id in ids {
                guard ticket.isLive else { return }
                let prepared = await host.prepareForBulkRun(itemID: id, ticket: ticket)
                guard ticket.isLive else { return }
                host.bulkRunDidFinishOne(prepared: prepared)
            }
            guard self.generation == started else { return }
            self.holder.clear()
            host.bulkRunDidComplete()
        })
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
