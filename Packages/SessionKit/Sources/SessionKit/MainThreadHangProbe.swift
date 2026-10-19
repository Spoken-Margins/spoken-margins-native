import Foundation

/// A stack of short names for the synchronous work the main thread is doing right now (#2099), such as
/// `run` or `refreshLibraryRows`. The hang probe reads it from its own thread while the main thread is stuck,
/// so a hang record can say what the main thread was in the middle of. Labels are fixed names written in
/// code; they hold no item titles, text or ids.
public final class MainThreadOperationLabels: @unchecked Sendable {
    public static let shared = MainThreadOperationLabels()

    private let lock = NSLock()
    private var entries: [(token: UInt64, label: String)] = []
    private var nextToken: UInt64 = 0

    public init() {}

    /// Puts `label` on top of the stack. Hand the returned token to `pop`.
    @discardableResult
    public func push(_ label: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextToken += 1
        entries.append((nextToken, String(label.prefix(40))))
        return nextToken
    }

    /// Takes the entry for `token` off the stack. An entry already gone is ignored.
    public func pop(_ token: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let index = entries.lastIndex(where: { $0.token == token }) { entries.remove(at: index) }
    }

    /// Runs `body` with `label` on the stack.
    public func scoped<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let token = push(label)
        defer { pop(token) }
        return try body()
    }

    /// The stack from the outermost label to the innermost, joined by `>`; empty when nothing is in flight.
    public var current: String {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.label).joined(separator: ">")
    }
}

/// Tells when the main thread answers late (#2099). A timer on its own queue sends an empty block to the main
/// queue every `intervalMs`. If the block runs `thresholdMs` or more after it was sent, the main thread was
/// stuck for about that long, and `onHang` is told once, on the main queue, after it comes free.
///
/// While a block waits, the probe's own thread reads `MainThreadOperationLabels`, so the hang names the work
/// the main thread was in. The duration is the wait of the oldest unanswered block, so it is a little under
/// the true stall (by up to one interval). Nothing runs on the main thread except that empty block, and the
/// report when there is a hang.
///
/// A phone that suspends the app freezes the probe's timer too. The probe notices a long gap between its own
/// ticks and drops the block in flight, so a suspension is never reported as a hang.
public final class MainThreadHangProbe: @unchecked Sendable {
    public struct Hang: Sendable, Equatable {
        /// How long the main thread took to answer, in milliseconds.
        public let durationMs: Int
        /// `MainThreadOperationLabels.current` as seen while the main thread was stuck; empty if no label was set.
        public let operation: String

        public init(durationMs: Int, operation: String) {
            self.durationMs = durationMs
            self.operation = operation
        }
    }

    public let thresholdMs: Int

    private let watched: DispatchQueue
    private let labels: MainThreadOperationLabels
    private let onHang: @Sendable (Hang) -> Void
    private let probeQueue = DispatchQueue(label: "spoken-margins.hang-probe", qos: .utility)

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var intervalMs = 0
    private var epoch: UInt64 = 0
    private var pendingSince: TimeInterval?
    private var stalledOperation = ""
    private var lastTick: TimeInterval?

    /// - Parameters:
    ///   - thresholdMs: the lateness that counts as a hang.
    ///   - watched: the queue whose liveness is checked; the main queue in the app, a private queue in tests.
    ///   - labels: where the in-flight work is named.
    ///   - onHang: called on `watched` once the hang is over.
    public init(
        thresholdMs: Int = 250,
        watched: DispatchQueue = .main,
        labels: MainThreadOperationLabels = .shared,
        onHang: @escaping @Sendable (Hang) -> Void
    ) {
        self.thresholdMs = thresholdMs
        self.watched = watched
        self.labels = labels
        self.onHang = onHang
    }

    deinit { timer?.cancel() }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    /// Starts checking every `intervalMs`, or changes the interval if the probe is already running.
    public func start(intervalMs: Int = 100) {
        let interval = max(10, intervalMs)
        lock.lock()
        defer { lock.unlock() }
        if timer != nil, self.intervalMs == interval { return }
        timer?.cancel()
        epoch &+= 1
        pendingSince = nil
        stalledOperation = ""
        lastTick = nil
        self.intervalMs = interval
        let source = DispatchSource.makeTimerSource(queue: probeQueue)
        source.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval), leeway: .milliseconds(interval / 2))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
        epoch &+= 1
        pendingSince = nil
        stalledOperation = ""
        lastTick = nil
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func tick() {
        let now = Self.now()
        lock.lock()
        guard timer != nil else { lock.unlock(); return }
        if let last = lastTick, (now - last) * 1000 > Double(max(intervalMs * 4, thresholdMs * 2)) {
            // The whole process was frozen, not just the main thread. The block in flight is stale.
            epoch &+= 1
            pendingSince = nil
            stalledOperation = ""
        }
        lastTick = now
        if let sent = pendingSince {
            if stalledOperation.isEmpty, (now - sent) * 1000 >= Double(thresholdMs) {
                stalledOperation = labels.current
            }
            lock.unlock()
            return
        }
        pendingSince = now
        let sentEpoch = epoch
        lock.unlock()
        watched.async { [weak self] in self?.answered(sentAt: now, epoch: sentEpoch) }
    }

    private func answered(sentAt sent: TimeInterval, epoch sentEpoch: UInt64) {
        let now = Self.now()
        lock.lock()
        guard sentEpoch == epoch else { lock.unlock(); return }
        pendingSince = nil
        var operation = stalledOperation
        stalledOperation = ""
        lock.unlock()
        let lateMs = Int(((now - sent) * 1000).rounded())
        guard lateMs >= thresholdMs else { return }
        if operation.isEmpty { operation = labels.current }
        onHang(Hang(durationMs: lateMs, operation: operation))
    }
}
