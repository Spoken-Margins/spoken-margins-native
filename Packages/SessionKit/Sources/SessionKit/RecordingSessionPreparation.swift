import Foundation

/// A recorder that can put the audio session in its recording configuration before `beginRecording`, away from the
/// main thread (#2511).
///
/// On Bluetooth headphones the switch to `playAndRecord` moves them from A2DP to the hands-free profile, and
/// `setCategory`/`setActive` wait for that on the calling thread. In the owner's Diagnostics (Build 35, 9c88103) every
/// Margin started on AirPods held the main thread for 0.9 to 1 s between "recorder requested" and "recorder
/// started", so the screen froze on the tap.
public protocol RecordingSessionPreparing: AnyObject {
    /// Starts the switch on a background queue and calls `then` on the main thread once it is done (or skipped).
    /// Call it only when nothing is sounding: a source still playing would be heard moving to the hands-free profile.
    /// `then` runs even when the switch failed: `beginRecording` then does the whole switch itself, as before.
    func prepareRecordingSession(then: @escaping @MainActor @Sendable () -> Void)
    /// No recording is coming (Cancel, or the pencil, before the recorder started). Waits for a switch still running,
    /// so no session call from it lands after this returns, then lets go of a session it changed, as
    /// `cancelRecording` does. Does nothing when nothing was prepared, or `beginRecording` already took it.
    func abandonRecordingSessionPreparation()
}

/// The ordering behind `RecordingSessionPreparing`, kept apart from AVFoundation so the host can test it.
///
/// One preparation at a time, on its own serial queue. `claim` and `abandon` both wait for a preparation that is still
/// running, so the caller's own session calls on the main thread never overlap it and never land before it.
/// `Context` is what the recorder read from the session before changing it (the route, whether other audio mixed),
/// because once the switch has run the session no longer says what it was.
public final class RecordingSessionPreparation<Context: Sendable>: @unchecked Sendable {
    public struct Claim: Sendable {
        public let context: Context
        /// Whether the preparation changed the session (false: it was skipped, or the switch threw).
        public let applied: Bool
        /// How long the switch took on the preparation queue.
        public let elapsedMs: Int?
    }

    private struct Pending {
        let generation: UInt64
        let context: Context
        var applied = false
        /// Any preparation since the first tap left the session switched, including one a second tap superseded
        /// while it ran. This, not `applied`, is what `abandon` lets go of.
        var sessionChanged = false
        var finished = false
        var elapsedMs: Int?
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending: Pending?
    private let clock: @Sendable () -> TimeInterval

    public init(
        label: String,
        qos: DispatchQoS = .userInitiated,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        queue = DispatchQueue(label: label, qos: qos)
        self.clock = clock
    }

    /// True between `prepare` and the `claim` or `abandon` that ends it.
    public var hasPending: Bool { lock.withLock { pending != nil } }

    /// Starts a preparation. `readContext` runs here, on the caller's thread, and only when no preparation is
    /// pending: a second tap keeps what the first one read, before its switch changed the session. `apply` runs on
    /// the preparation queue and returns whether it left the session in the recording configuration and active
    /// (true also when the configuration was already right), which is what `abandon` must let go of. `then` runs on the main thread afterwards,
    /// whether `apply` ran, threw or was skipped because a newer `prepare` or an `abandon` came first.
    public func prepare(
        readContext: () -> Context,
        apply: @escaping @Sendable (Context) -> Bool,
        then: @escaping @MainActor @Sendable () -> Void
    ) {
        let earlier = lock.withLock { pending?.context }
        let context = earlier ?? readContext()
        let mine: UInt64 = lock.withLock {
            generation &+= 1
            let changed = pending?.sessionChanged ?? false
            pending = Pending(generation: generation, context: context)
            pending?.sessionChanged = changed
            return generation
        }
        queue.async { [self] in
            // Skipped when a newer `prepare` or an `abandon` came before the queue reached it.
            if lock.withLock({ generation == mine && pending?.generation == mine }) {
                let start = clock()
                let applied = apply(context)
                let elapsedMs = max(0, Int(((clock() - start) * 1_000).rounded()))
                lock.withLock {
                    // Recorded even when an `abandon` is waiting on this queue, or a newer tap superseded this one
                    // mid-switch: either way the session was changed and must be let go if no recording comes.
                    if applied { pending?.sessionChanged = true }
                    guard pending?.generation == mine else { return }
                    pending?.applied = applied
                    pending?.finished = true
                    pending?.elapsedMs = elapsedMs
                }
            }
            Task { @MainActor in then() }
        }
    }

    /// Takes the current preparation for the recorder starting now. Waits for one still running, so the recorder's
    /// own session calls come after it. Nil when nothing was prepared.
    public func claim() -> Claim? {
        guard hasPending else { return nil }
        queue.sync {}
        return lock.withLock {
            defer { pending = nil }
            guard let pending, pending.generation == generation else { return nil }
            return Claim(context: pending.context, applied: pending.applied, elapsedMs: pending.elapsedMs)
        }
    }

    /// Drops the preparation: one not yet started never runs, one running is waited for. Returns whether it had
    /// changed the session, so the caller lets go of it. False when nothing was pending or it was already claimed.
    @discardableResult
    public func abandon() -> Bool {
        let hadPending = lock.withLock { () -> Bool in
            guard pending != nil else { return false }
            generation &+= 1
            return true
        }
        guard hadPending else { return false }
        queue.sync {}
        return lock.withLock {
            defer { pending = nil }
            return pending?.sessionChanged ?? false
        }
    }

    /// Returns once everything queued so far has run or been skipped. For tests.
    public func waitUntilIdle() {
        queue.sync {}
    }
}
