/// Callers that wait for a running pass to end (#4955). Following's pull-down refresh is its only manual refresh, and a
/// pull made while a refresh runs starts no second pass: the running pass goes round once more for it (`RunAgainGate`).
/// The pull waits here so its spinner stays until that pass ends. The pass calls `passEnded()` once it stops, and every
/// waiter then returns. A waiter that starts after `passEnded()` waits for the next one.
@MainActor
public final class PassEndWaiters {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// How many callers are waiting now.
    public var waitingCount: Int { waiters.count }

    /// Returns when the pass that is running now ends.
    public func waitForEnd() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The pass ended: every caller waiting now returns.
    public func passEnded() {
        let ending = waiters
        waiters = []
        for waiter in ending { waiter.resume() }
    }
}
