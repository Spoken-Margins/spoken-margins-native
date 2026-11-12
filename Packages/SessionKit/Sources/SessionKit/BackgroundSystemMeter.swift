import Foundation

/// The readings iOS acts on when it decides a backgrounded app has to go, as one seam (#3936): the wall clock, the
/// process's CPU clock, and a way to wait. The app's code takes them from here, so a host test can hand it a
/// `SimulatedIOSBackground` that keeps iOS's own books and says whether iOS would have stopped the app.
public protocol SystemReadings: Sendable {
    /// Monotonic seconds.
    func uptime() -> TimeInterval
    /// CPU seconds the whole process has used, across every thread.
    func processCPUTime() -> TimeInterval
    /// Waits `seconds` on the caller's thread.
    func sleep(_ seconds: TimeInterval)
}

/// The real clocks: what the app passes in production.
public struct LiveSystemReadings: SystemReadings {
    public init() {}

    public func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func processCPUTime() -> TimeInterval { OnDeviceVoiceGovernor.processCPUTime() }
    public func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}

/// The thresholds iOS applies to a backgrounded audio app. Our own budgets (`OnDeviceCPUBudget`) sit under these on
/// purpose; a host test checks the app against these, not against its own budget, so a budget that is too generous
/// cannot grade itself.
public struct IOSBackgroundKillRules: Equatable, Sendable {
    /// Share of one core, averaged over `cpuWindow`, above which iOS ends a background app (`cpu_resource`; the
    /// 80% over 60 s that #1679's and #2695's termination traces showed). More than 1 is possible: CPU counts every thread.
    public var cpuShare: Double
    public var cpuWindow: TimeInterval
    /// How long the main thread may be blocked in the background, or while the app changes scenes, before the
    /// watchdog ends it. iOS does not publish this. The #2184 export shows an app killed after the main thread had been
    /// stuck for about 10 s, so this is the figure to stay well under, not iOS's own.
    public var mainThreadStallLimit: TimeInterval

    public init(cpuShare: Double = 0.8, cpuWindow: TimeInterval = 60, mainThreadStallLimit: TimeInterval = 10) {
        self.cpuShare = cpuShare
        self.cpuWindow = cpuWindow
        self.mainThreadStallLimit = mainThreadStallLimit
    }

    /// CPU seconds in `cpuWindow` above which the app is ended.
    public var cpuLimit: TimeInterval { cpuShare * cpuWindow }
}

/// A hand-driven iOS: a fake clock, a fake process CPU clock, and iOS's kill rules applied to both. A test moves time
/// with `advance` (or lets code under test call `sleep`), says what the app is doing, and reads `kill`, which is nil
/// while iOS would leave the app alone. The first kill stays; time goes on after it so a replay can finish.
///
/// It models the meter, not the app: the CPU a piece of code uses is whatever the test says it uses. The code under
/// test is real; only the numbers iOS reads off it are scripted.
public final class SimulatedIOSBackground: SystemReadings, @unchecked Sendable {
    public enum Reason: Equatable, Sendable {
        /// More CPU than `IOSBackgroundKillRules.cpuLimit` in the window while in the background.
        case cpuResource(cpuSeconds: TimeInterval, window: TimeInterval)
        /// The main thread was blocked at least `mainThreadStallLimit` in the background or during a scene change.
        case watchdog(stall: TimeInterval)
    }

    public struct Kill: Equatable, Sendable {
        public let at: TimeInterval
        public let reason: Reason
        public let whileBackgrounded: Bool
    }

    private struct Segment { var start: TimeInterval; var end: TimeInterval; var cpu: TimeInterval }

    public let rules: IOSBackgroundKillRules
    /// CPU the app spends per second of wall time on top of what the test says: the player's decoding, the cache, SQLite
    /// saves and diagnostics, which `OnDeviceCPUBudget` does not charge.
    public let idleCPUShare: Double

    private let lock = NSLock()
    private var wall: TimeInterval = 0
    private var cpu: TimeInterval = 0
    private var segments: [Segment] = []
    private var backgroundedAt: TimeInterval?
    private var changingScenes = false
    private var firstKill: Kill?
    private var busiest: TimeInterval = 0

    public init(rules: IOSBackgroundKillRules = IOSBackgroundKillRules(), idleCPUShare: Double = 0) {
        self.rules = rules
        self.idleCPUShare = idleCPUShare
    }

    public func uptime() -> TimeInterval { lock.withLock { wall } }
    public func processCPUTime() -> TimeInterval { lock.withLock { cpu } }
    public func sleep(_ seconds: TimeInterval) { advance(wall: seconds) }

    /// The first time iOS would have ended the app, or nil.
    public var kill: Kill? { lock.withLock { firstKill } }
    public var isBackgrounded: Bool { lock.withLock { backgroundedAt != nil } }
    /// The most CPU any `cpuWindow` of background time has held so far: how close the app came to the limit.
    public var busiestBackgroundWindowCPU: TimeInterval { lock.withLock { busiest } }

    public func enterBackground() {
        lock.withLock { if backgroundedAt == nil { backgroundedAt = wall } }
    }

    /// The app comes to the front. iOS's watchdog covers the scene change that follows, until `sceneDidSettle`.
    public func enterForeground() {
        lock.withLock { backgroundedAt = nil; changingScenes = true }
    }

    public func sceneDidSettle() {
        lock.withLock { changingScenes = false }
    }

    /// Time passes: `wall` seconds, during which the app's threads together used `cpu` seconds of CPU (more than
    /// `wall` when several threads ran), plus `idleCPUShare` of the wall time.
    public func advance(wall seconds: TimeInterval, cpu used: TimeInterval = 0) {
        lock.withLock { advanceLocked(wall: seconds, cpu: used) }
    }

    /// A long step is metered in slices of at most a second, so the busiest trailing minute is found to the second even
    /// when the test moves time in one big step.
    private func advanceLocked(wall seconds: TimeInterval, cpu used: TimeInterval) {
        guard seconds > 0 || used > 0 else { return }
        let slices = max(1, Int((seconds / Self.meterStep).rounded(.up)))
        for _ in 0..<slices {
            let share = 1 / TimeInterval(slices)
            let length = seconds * share
            let total = (used + idleCPUShare * seconds) * share
            segments.append(Segment(start: wall, end: wall + length, cpu: total))
            wall += length
            cpu += total
            meterCPU()
        }
    }

    private static let meterStep: TimeInterval = 1

    /// The main thread is blocked for `seconds` (a synchronous store read, a daemon call): wall time passes, and the
    /// blocked thread itself burns `cpu` (none by default: a thread waiting on a daemon burns none, one reading a table burns it all).
    ///
    /// One call is one continuous stall: two 6 s calls are two stalls, not one of 12 s.
    public func blockMainThread(for seconds: TimeInterval, cpu used: TimeInterval = 0) {
        lock.withLock {
            let watched = backgroundedAt != nil || changingScenes
            let alreadyDead = firstKill != nil
            advanceLocked(wall: seconds, cpu: used)
            guard !alreadyDead, watched, seconds >= rules.mainThreadStallLimit else { return }
            // The watchdog fires when the stall reaches its limit, which is before a CPU kill that only the end of the stall shows.
            let at = wall - seconds + rules.mainThreadStallLimit
            if firstKill == nil || at < firstKill!.at {
                firstKill = Kill(at: at, reason: .watchdog(stall: seconds), whileBackgrounded: backgroundedAt != nil)
            }
        }
    }

    /// What MetricKit's `applicationExitMetrics` would carry for this run, in the shape `PreviousRunExit` reads; nil
    /// when iOS left the app alone. The next launch's Diagnostics event is built from it.
    public func exitMetricsReport() -> Data? {
        guard let kill = lock.withLock({ firstKill }) else { return nil }
        let section = kill.whileBackgrounded ? "backgroundExitData" : "foregroundExitData"
        let key: String
        switch kill.reason {
        case .cpuResource: key = "cumulativeCPUResourceLimitExitCount"
        case .watchdog: key = "cumulativeAppWatchdogExitCount"
        }
        let json = """
        {"timeStampBegin":"2026-11-12 00:00:00","timeStampEnd":"2026-11-12 23:59:00","applicationExitMetrics":{"\(section)":{"\(key)":1}}}
        """
        return Data(json.utf8)
    }

    /// Called with the lock held after every advance.
    private func meterCPU() {
        segments.removeAll { $0.end < wall - rules.cpuWindow }
        guard let since = backgroundedAt else { return }
        let from = max(wall - rules.cpuWindow, since)
        var inWindow: TimeInterval = 0
        for segment in segments where segment.end > from || (segment.start == segment.end && segment.end >= from) {
            let length = segment.end - segment.start
            let overlap = segment.end - max(segment.start, from)
            inWindow += length > 0 ? segment.cpu * min(1, overlap / length) : segment.cpu
        }
        busiest = max(busiest, inWindow)
        if firstKill == nil, inWindow > rules.cpuLimit {
            firstKill = Kill(at: wall, reason: .cpuResource(cpuSeconds: inWindow, window: min(rules.cpuWindow, wall - since)),
                             whileBackgrounded: true)
        }
    }
}
