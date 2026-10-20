import Foundation

/// Retries the automatic resume after an interruption that said playback may resume (#2183).
///
/// On the owner's phone, locked and in Low Power Mode, another app's audio ended with "should resume" and the
/// resume's `setActive(true)` failed once ("Session activation failed"). The app gave up after that one attempt and
/// playback stayed paused until he pressed play. iOS can refuse activation for a moment right after another app lets
/// go of the session, so the resume is tried again a few times with growing waits, then left paused with the reason.
///
/// The retries stop at once if the listener has taken over (`stillWaiting` turns false), if `cancel()` is called, or
/// when the delays run out. They also stop if the retry window has passed: once playback fails, iOS suspends an app
/// with nothing playing, `Task.sleep` keeps counting while it is suspended, and the sleep would be over by the time the
/// app next ran, hours later. A resume that late would start the episode aloud with no one asking for it, so the
/// window is checked on the continuous clock before every attempt.
@MainActor
public final class InterruptionResumeRetrier {
    public enum Outcome: Equatable, Sendable {
        /// Playback resumed on retry `attempt` (1 is the first retry).
        case resumed(attempt: Int)
        /// Retry `attempt` failed again; another follows after the next delay.
        case retryFailed(attempt: Int, reason: String)
        /// The delays ran out. Playback stays paused for the listener to resume.
        case gaveUp(attempts: Int, reason: String)
        /// The listener or a new item took over before a retry ran, or the retry window had passed (the app was
        /// suspended while it waited), so the retry did not run.
        case abandoned(attempts: Int)
    }

    /// Waits before each retry, in milliseconds: about 15 s in all, long enough for another app to let go of the
    /// session, short enough that a resume the listener has forgotten about does not start much later.
    public static let defaultDelaysMs = [1_000, 2_000, 4_000, 8_000]

    /// Time allowed beyond the sum of the delays for the attempts themselves and for scheduling.
    public static let windowSlackMs = 2_000

    private let delaysMs: [Int]
    private let sleep: @Sendable (Int) async -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var task: Task<Void, Never>?
    /// The task `cancel()` last stopped, so a test can wait for it to wind down.
    private var cancelledTask: Task<Void, Never>?

    public init(
        delaysMs: [Int] = InterruptionResumeRetrier.defaultDelaysMs,
        sleep: @escaping @Sendable (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.delaysMs = delaysMs
        self.sleep = sleep
        self.now = now
    }

    public var isRetrying: Bool { task != nil }

    /// Starts retrying after a resume that failed with `firstError`. Replaces any retry already running.
    public func begin(
        after firstError: Error,
        stillWaiting: @escaping @MainActor () -> Bool,
        attempt: @escaping @MainActor () throws -> Void,
        report: @escaping @MainActor (Outcome) -> Void
    ) {
        cancel()
        let firstReason = Self.describe(firstError)
        let delays = delaysMs
        let sleep = self.sleep
        let now = self.now
        let deadline = now() + .milliseconds(delays.reduce(0, +) + Self.windowSlackMs)
        task = Task { @MainActor [weak self] in
            var lastReason = firstReason
            for (index, delay) in delays.enumerated() {
                await sleep(delay)
                guard !Task.isCancelled else { return }
                guard now() <= deadline, stillWaiting() else {
                    report(.abandoned(attempts: index))
                    self?.task = nil
                    return
                }
                do {
                    try attempt()
                    report(.resumed(attempt: index + 1))
                    self?.task = nil
                    return
                } catch {
                    lastReason = Self.describe(error)
                    if index + 1 < delays.count {
                        report(.retryFailed(attempt: index + 1, reason: lastReason))
                    }
                }
            }
            report(.gaveUp(attempts: delays.count, reason: lastReason))
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        if let task { cancelledTask = task }
        task = nil
    }

    /// Returns once a running retry has finished or been cancelled. For tests.
    public func waitUntilIdle() async {
        await (task ?? cancelledTask)?.value
    }

    /// The error's text with its domain and code, so an export says why iOS refused (#2183).
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }
}
