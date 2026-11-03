import Foundation

/// One pass at a time, without losing a request that arrives while it runs (#2136).
///
/// Import Retry and the followed-shows refresh each guarded their pass with a busy flag and returned early when it
/// was up. A request made during a pass (a Retry tap, a pull to refresh) was dropped: the screen said "queued" and
/// nothing ran until the app was next opened. With this gate the running pass notes the request and goes round once
/// more before it finishes. Any number of requests during one pass make one more pass, and a forced request is
/// never downgraded by an unforced one that came after it.
public struct RunAgainGate: Equatable, Sendable {
    public private(set) var isRunning = false
    public private(set) var hasPending = false
    public private(set) var pendingForced = false

    public init() {}

    /// Asks for a pass. `true`: the caller owns the pass and must call `finishPass()` after each round.
    /// `false`: a pass is already running; it will run once more with this request's strength.
    public mutating func request(forced: Bool = false) -> Bool {
        if isRunning {
            hasPending = true
            pendingForced = pendingForced || forced
            return false
        }
        isRunning = true
        return true
    }

    /// Call when a round ends. Returns `nil` when nothing was asked for meanwhile (the gate is free again), or the
    /// forced flag for the next round (the gate stays held for the caller).
    public mutating func finishPass() -> Bool? {
        guard hasPending else {
            isRunning = false
            return nil
        }
        let forced = pendingForced
        hasPending = false
        pendingForced = false
        return forced
    }
}
