import Foundation

/// Brings the episode or article back when a Margin's voice ends, and does not give up on the first refusal (#4110).
///
/// On the owner's phone, with the screen locked, a friend's Margin ended and `resumePlayback()` threw. The app reported it
/// once as a banner nobody saw and left the episode paused until he pressed Play. iOS can refuse to start the player or
/// activate the audio session for a moment in the background, which is the case `InterruptionResumeRetrier` already
/// handles for an interruption. This is the same retry for the return from a Margin, plus a record of why it failed that
/// carries no listener data.
///
/// The first attempt runs at once. A refusal is recorded and retried with the retrier's growing waits while the source
/// is still paused where it was. If every retry is refused, `report` gets `.gaveUp` and the caller tells the listener
/// and offers a button.
@MainActor
public final class MarginReturnResume {
    public enum Event: Equatable, Sendable {
        /// The first attempt threw. A retry follows unless the listener has taken over.
        case failed(reason: String)
        case resumedOnRetry(attempt: Int)
        case retryFailed(attempt: Int, reason: String)
        /// Every retry was refused. The source stays paused for the listener to resume.
        case gaveUp(attempts: Int, reason: String)
        /// The listener or a new item took over, or the retry window passed, before a retry ran.
        case abandoned(attempts: Int)

        /// The playback-event record kind.
        public static let recordKind = "margin.return_resume"

        /// What goes into the Diagnostics record: the outcome, the attempt and the error's domain, code and case name
        /// (`SafeErrorText`), never a message.
        public var fields: [String: String] {
            switch self {
            case .failed(let reason): return ["outcome": "failed", "attempt": "0", "error": reason]
            case .resumedOnRetry(let attempt): return ["outcome": "resumed_on_retry", "attempt": String(attempt)]
            case .retryFailed(let attempt, let reason): return ["outcome": "retry_failed", "attempt": String(attempt), "error": reason]
            case .gaveUp(let attempts, let reason): return ["outcome": "gave_up", "attempt": String(attempts), "error": reason]
            case .abandoned(let attempts): return ["outcome": "abandoned", "attempt": String(attempts)]
            }
        }
    }

    private let retrier: InterruptionResumeRetrier

    public init(retrier: InterruptionResumeRetrier = InterruptionResumeRetrier()) {
        self.retrier = retrier
    }

    public var isRetrying: Bool { retrier.isRetrying }

    /// Resumes now. Returns true when that worked. On a refusal returns false after reporting `.failed` and starting the
    /// retries, so the caller shows nothing yet.
    @discardableResult
    public func resume(
        stillWaiting: @escaping @MainActor () -> Bool,
        attempt: @escaping @MainActor () throws -> Void,
        report: @escaping @MainActor (Event) -> Void
    ) -> Bool {
        retrier.cancel() // a return that starts over replaces one still retrying
        do {
            try attempt()
            return true
        } catch {
            report(.failed(reason: SafeErrorText.describe(error)))
            retrier.begin(after: error, stillWaiting: stillWaiting, attempt: attempt) { outcome in
                switch outcome {
                case .resumed(let n): report(.resumedOnRetry(attempt: n))
                case .retryFailed(let n, let reason): report(.retryFailed(attempt: n, reason: reason))
                case .gaveUp(let n, let reason): report(.gaveUp(attempts: n, reason: reason))
                case .abandoned(let n): report(.abandoned(attempts: n))
                }
            }
            return false
        }
    }

    /// The listener took over (pause, seek, another item): a retry still waiting must not start the source.
    public func cancel() { retrier.cancel() }

    /// Returns once a running retry has finished or been cancelled. For tests.
    public func waitUntilIdle() async { await retrier.waitUntilIdle() }
}
