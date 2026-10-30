import Foundation

/// Runs blocking system calls (audio-session activation, an ActivityKit permission check) away from the main thread,
/// one at a time, newest request first in line (#2967). A call that waits on a system daemon freezes the main thread
/// for as long as the daemon takes, which on a busy phone is seconds. The work that used to make the call inline
/// hands it here instead.
///
/// Only the newest request is worth running: when a newer `submit` or a `cancelPending` arrives before the queue
/// reaches an older one, the older one is skipped. So a burst of status changes activates the session once, and a
/// request made stale by a pause or an end never runs after it.
public final class LatestOnlyBackgroundWork: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// Queues `work`. It is skipped if another `submit` or `cancelPending` happens before it starts.
    public func submit(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        generation &+= 1
        let mine = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(mine) else { return }
            work()
        }
    }

    /// Drops every request that has not started.
    public func cancelPending() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    /// Returns once everything queued so far has run or been skipped. For tests.
    public func waitUntilIdle() {
        queue.sync {}
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }
}

/// A yes/no answer that only a blocking system call can give, read without blocking the caller (#2967).
/// `value` is the last answer, or `initial` before the first one. Once the answer is `maxAge` seconds old, reading
/// `value` starts one refresh on a background queue and still returns at once with the last answer; the refresh
/// replaces it. The caller therefore sees a change at most one `maxAge` late, which is fine for a setting a
/// listener changes in the Settings app.
public final class RefreshedSystemFlag: @unchecked Sendable {
    private let maxAge: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let read: @Sendable () -> Bool
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var answer: Bool
    private var readAt: TimeInterval?
    private var refreshing = false

    public init(
        initial: Bool,
        maxAge: TimeInterval = 5,
        label: String = "spoken-margins.system-flag",
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        read: @escaping @Sendable () -> Bool
    ) {
        self.answer = initial
        self.maxAge = maxAge
        self.clock = clock
        self.read = read
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    public var value: Bool {
        lock.lock()
        let current = answer
        let stale = readAt.map { clock() - $0 >= maxAge } ?? true
        let start = stale && !refreshing
        if start { refreshing = true }
        lock.unlock()
        if start {
            queue.async { [self] in
                let fresh = read()
                lock.lock()
                answer = fresh
                readAt = clock()
                refreshing = false
                lock.unlock()
            }
        }
        return current
    }

    /// Returns once a refresh in flight has landed. For tests.
    public func waitUntilIdle() {
        queue.sync {}
    }
}
