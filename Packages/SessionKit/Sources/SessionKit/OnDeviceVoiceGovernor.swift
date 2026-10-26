import Foundation

/// Who a render is for, which decides whether its inference is paced (#377).
public enum OnDeviceRenderPacing: Equatable, Sendable {
    /// The listener's live narration: paced only while the app is in the background.
    case whenAppBackgrounded
    /// Background preparation: always paced, so it never competes with live narration for CPU.
    case always
}

/// The rules every on-device voice's inference goes through: Supertonic, the bundled Kitten voice, and any voice
/// added later (#1679). They used to live inside the Supertonic renderer, so when heat handed narration to Kitten,
/// Kitten rendered flat out in the background and iOS stopped the app for using too much CPU.
///
/// One instance holds the app's state for every voice: whether the app is in the background, and what the device
/// reports (heat, Low Power Mode, a recent memory warning). The app keeps one; every renderer requires it, so a voice
/// can't be built without pacing. A renderer runs each inference through `measureInference(_:)`, then either rests
/// at once (`rest(after:pacing:shouldContinue:)`, Supertonic between its steps) or notes `nextInference(after:pacing:)`
/// and waits it out at the start of its next render (`waitForNextInference`, Kitten and Pocket), so a rest never
/// delays the chunk just made and a cancelled render doesn't sit through one.
public final class OnDeviceVoiceGovernor: @unchecked Sendable {
    /// What one inference cost: wall time, and the process's CPU time over it when known. A voice that runs inference
    /// on several threads (Kitten uses two) spends more CPU than wall time, and iOS's background limit counts CPU.
    public struct InferenceCost: Equatable, Sendable {
        public var wall: TimeInterval
        public var cpu: TimeInterval?

        public init(wall: TimeInterval, cpu: TimeInterval? = nil) {
            self.wall = wall
            self.cpu = cpu
        }
    }

    private let lock = NSLock()
    private var appBackgrounded = false
    /// Every renderer's inference CPU in the last minute, shared across voices while the app is away (#2695).
    private var budget = OnDeviceCPUBudget()
    /// Asks the playing client what live narration has waiting (#2695). Read at every budget check, never cached, so
    /// a seek, a skip or a start on an unrendered chunk is seen at once; nil when no client plays.
    private var liveBuffer: (@Sendable () -> LiveNarrationBuffer?)?
    private let conditionsProvider: @Sendable () -> SpeechEngineConditions
    private let now: @Sendable () -> TimeInterval
    private let cpuTime: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) -> Void
    #if DEBUG
    private var records: [(pacing: OnDeviceRenderPacing, inference: TimeInterval, delay: TimeInterval)] = []
    /// Each inference's pacing: who asked for the render, how long it ran and how long it was held back after.
    public var debugPacingRecords: [(pacing: OnDeviceRenderPacing, inference: TimeInterval, delay: TimeInterval)] {
        lock.withLock { records }
    }
    #endif

    /// `conditions` reads the device (the app passes `SupertonicResourcePolicy`'s); `now`, `cpuTime` and `sleep` are
    /// for host tests. Production uses the monotonic system clock, the process's CPU clock and a real sleep.
    public init(
        conditions: @escaping @Sendable () -> SpeechEngineConditions = { SpeechEngineConditions() },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        cpuTime: @escaping @Sendable () -> TimeInterval = { OnDeviceVoiceGovernor.processCPUTime() },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.conditionsProvider = conditions
        self.now = now
        self.cpuTime = cpuTime
        self.sleep = sleep
    }

    /// CPU time the whole process has used, in seconds; 0 when the clock can't be read.
    public static func processCPUTime() -> TimeInterval {
        var time = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0 else { return 0 }
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    /// Whether the app is in the background: set from the app's lifecycle only. Live narration is paced there so
    /// it stays under iOS's sustained CPU limit for background audio apps; in front it is not, so the first chunks
    /// start quickly.
    public func setAppBackgrounded(_ backgrounded: Bool) {
        lock.withLock { appBackgrounded = backgrounded }
    }

    public var isAppBackgrounded: Bool {
        lock.withLock { appBackgrounded }
    }

    /// The playing client registers how to read live narration's buffer (#2695). The governor pulls it at each budget
    /// check instead of being told, so no path that moves the play head can leave a stale answer behind. A later
    /// registration replaces an earlier one; the client that plays last is the live one. `buffer` is called without
    /// the governor's lock held, so it may take the client's own lock.
    public func readLiveNarrationBuffer(with buffer: @escaping @Sendable () -> LiveNarrationBuffer?) {
        lock.withLock { liveBuffer = buffer }
    }

    /// Whether live narration may not wait on the shared budget now: its play head waits on audio, or less than
    /// `OnDeviceCPUBudget.liveReserve` of listening waits ahead. While it is, live narration keeps only its own duty
    /// cycle, and its CPU still counts against every other render, so the budget slows render-ahead but never
    /// starves the playing buffer.
    public var liveNarrationNeedsAudio: Bool {
        let buffer = lock.withLock { liveBuffer }
        return buffer?()?.needsAudio ?? false
    }

    /// When a render with `pacing` may start its next inference under the shared background budget; nil when the
    /// budget doesn't hold it: the app is in front, or this is live narration and the play head waits on audio or is
    /// running low (`liveNarrationNeedsAudio`), so a render the listener is waiting for never waits on the budget.
    public func budgetStart(for pacing: OnDeviceRenderPacing) -> TimeInterval? {
        guard isAppBackgrounded else { return nil }
        // Read outside the lock: the client's answer takes the client's lock, which is always taken before this one.
        if pacing == .whenAppBackgrounded, liveNarrationNeedsAudio { return nil }
        let time = now()
        return lock.withLock { () -> TimeInterval? in
            guard appBackgrounded else { return nil }
            let start = budget.earliestStart(now: time)
            return start > time ? start : nil
        }
    }

    /// The inference CPU every renderer charged in the last `OnDeviceCPUBudget.window`.
    public func budgetSpent() -> TimeInterval {
        let time = now()
        return lock.withLock { budget.spent(now: time) }
    }

    func reserveInference() -> TimeInterval {
        let time = now()
        return lock.withLock { budget.reserve(now: time) }
    }

    func settleInference(reserved: TimeInterval, cpu: TimeInterval) {
        let time = now()
        lock.withLock { budget.settle(reserved: reserved, cpu: cpu, now: time) }
    }

    /// What the device reports now.
    public func conditions() -> SpeechEngineConditions {
        conditionsProvider()
    }

    /// I14: what refuses Supertonic now (heat, a memory warning); nil when it may render. The bundled voice takes
    /// over while this is set (#849).
    public func supertonicRenderingBlock() -> SpeechFallbackReason? {
        SpeechEnginePolicy.onDeviceRenderingBlock(conditions())
    }

    /// Whether a render with `pacing` is paced now.
    public func isPaced(_ pacing: OnDeviceRenderPacing) -> Bool {
        pacing == .always || isAppBackgrounded
    }

    /// How long a render with `pacing` rests after `inference` seconds of inference, now.
    public func pacingDelay(afterInference inference: TimeInterval, for pacing: OnDeviceRenderPacing) -> TimeInterval {
        pacingDelay(after: InferenceCost(wall: inference), for: pacing)
    }

    /// How long a render with `pacing` rests after an inference that cost `cost`, now.
    public func pacingDelay(after cost: InferenceCost, for pacing: OnDeviceRenderPacing) -> TimeInterval {
        OnDeviceInferencePacingPolicy.delay(after: cost, backgrounded: isPaced(pacing))
    }

    /// Runs one inference and says what it cost, for `rest(after:pacing:shouldContinue:)`. The cost is charged to the
    /// shared budget, CPU time where the clock gives it and wall time otherwise (#2695).
    public func measureInference<T>(_ inference: () throws -> T) rethrows -> (value: T, cost: InferenceCost) {
        let reserved = reserveInference()
        let wallStart = now()
        let cpuStart = cpuTime()
        var settled = false
        defer { if !settled { settleInference(reserved: reserved, cpu: max(0, cpuTime() - cpuStart)) } }
        let value = try inference()
        let cpu = cpuTime() - cpuStart
        let cost = InferenceCost(wall: max(0, now() - wallStart), cpu: cpu > 0 ? cpu : nil)
        settleInference(reserved: reserved, cpu: cost.cpu ?? cost.wall)
        settled = true
        return (value, cost)
    }

    /// Waits while the shared budget holds a render with `pacing` (#2695). Re-read after every wake, since another
    /// renderer may have charged it meanwhile or the app may have come to the front.
    private func waitForBudget(pacing: OnDeviceRenderPacing, shouldContinue: () throws -> Bool) rethrows {
        while try shouldContinue(), let start = budgetStart(for: pacing) {
            sleep(min(0.1, max(0.001, start - now())))
        }
    }

    /// Rests after `inference` seconds of inference. See `rest(after:pacing:shouldContinue:)`.
    public func rest(
        afterInference inference: TimeInterval,
        pacing: OnDeviceRenderPacing,
        shouldContinue: () throws -> Bool
    ) rethrows {
        try rest(after: InferenceCost(wall: inference), pacing: pacing, shouldContinue: shouldContinue)
    }

    /// When the voice's next inference may start after one that cost `cost`; nil when it needn't wait.
    public func nextInference(after cost: InferenceCost, pacing: OnDeviceRenderPacing) -> TimeInterval? {
        let delay = pacingDelay(after: cost, for: pacing)
        #if DEBUG
        lock.withLock { records.append((pacing, cost.wall, delay)) }
        #endif
        return delay > 0 ? now() + delay : nil
    }

    /// Waits until `notBefore` (from `nextInference(after:pacing:)`, nil for none) and then while the shared budget
    /// holds the render, before the next inference. Time spent idle since counts. Ends early once a render with
    /// `pacing` is no longer paced (the app came to the front) or `shouldContinue` says to stop; it throws what
    /// `shouldContinue` throws, such as a cancellation.
    public func waitForNextInference(
        notBefore: TimeInterval?, pacing: OnDeviceRenderPacing, shouldContinue: () throws -> Bool
    ) rethrows {
        if let notBefore {
            try OnDeviceInferencePacingPolicy.wait(for: notBefore - now(), now: now, sleep: sleep) {
                try shouldContinue() && isPaced(pacing)
            }
        }
        try waitForBudget(pacing: pacing, shouldContinue: shouldContinue)
    }

    /// Rests after an inference that cost `cost`, on the caller's thread, so the voice's next inference waits.
    /// Ends early once the render is no longer paced (the app came to the front) or `shouldContinue` says to stop;
    /// it throws what `shouldContinue` throws, such as a cancellation.
    public func rest(
        after cost: InferenceCost,
        pacing: OnDeviceRenderPacing,
        shouldContinue: () throws -> Bool
    ) rethrows {
        let delay = pacingDelay(after: cost, for: pacing)
        #if DEBUG
        lock.withLock { records.append((pacing, cost.wall, delay)) }
        #endif
        try OnDeviceInferencePacingPolicy.wait(for: delay, now: now, sleep: sleep) {
            try shouldContinue() && isPaced(pacing)
        }
        try waitForBudget(pacing: pacing, shouldContinue: shouldContinue)
    }
}

public enum OnDeviceInferencePacingPolicy {
    /// ONNX occupied roughly 85% of one CPU in the device termination traces.
    /// Holding inference work to 65% of wall time leaves margin below iOS's 80%
    /// sustained-background limit for playback and application bookkeeping.
    public static let backgroundWorkDutyCycle = 0.65

    public static func delay(afterInferenceDuration duration: TimeInterval, backgrounded: Bool) -> TimeInterval {
        delay(after: OnDeviceVoiceGovernor.InferenceCost(wall: duration), backgrounded: backgrounded)
    }

    /// The rest that holds the process's CPU over the inference and the rest to the duty cycle. CPU below the wall
    /// time (one thread, partly idle) is counted as the wall time, so a single-threaded voice is paced as before
    /// (#1101); CPU above it (inference on several threads) lengthens the rest (#1679).
    public static func delay(after cost: OnDeviceVoiceGovernor.InferenceCost, backgrounded: Bool) -> TimeInterval {
        guard backgrounded, cost.wall > 0 else { return 0 }
        let work = max(cost.wall, cost.cpu ?? 0)
        return work / backgroundWorkDutyCycle - cost.wall
    }

    /// Scheduler delay already rests inference. In the background a 100 ms sleep may wake much
    /// later; subtracting only the requested 100 ms would repeatedly add that delay (#1101).
    /// Clock and sleep are injected for host tests; production uses the monotonic system clock.
    public static func wait(
        for duration: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        shouldContinue: () throws -> Bool
    ) rethrows {
        let deadline = now() + duration
        while true {
            guard try shouldContinue() else { return }
            let remaining = deadline - now()
            guard remaining > 0 else { return }
            sleep(min(0.1, remaining))
        }
    }
}

/// What live narration has waiting, as the playing client reads it from its own state at the moment of asking (#2695).
public struct LiveNarrationBuffer: Equatable, Sendable {
    /// Listening rendered and waiting past the playing chunk, at the listener's speed.
    public var listeningAhead: TimeInterval
    /// The play head is waiting for a chunk that isn't rendered yet: a start, a seek or skip, or a render gap.
    public var playheadWaitsForAudio: Bool

    public init(listeningAhead: TimeInterval, playheadWaitsForAudio: Bool) {
        self.listeningAhead = listeningAhead
        self.playheadWaitsForAudio = playheadWaitsForAudio
    }

    /// Live narration must not wait on the shared budget.
    public var needsAudio: Bool {
        playheadWaitsForAudio || listeningAhead < OnDeviceCPUBudget.liveReserve
    }
}
