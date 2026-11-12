import Foundation

/// Brings the source back after a Margin's voice ends, and says what happened when it can't (#4110).
///
/// A friend's Margin pauses the episode, plays, and then asks the engine to resume it. On the owner's phone, with the
/// screen locked, that resume threw once (the audio session is refused for a moment in the background, as in #2183),
/// the app showed an error banner nobody could see, never tried again, and the episode stayed paused and silent until
/// he pressed play. Three things change:
/// 1. A failed resume writes a `resume.failed` playback event with the error's type and domain/code (no message text),
///    so the next device export names the cause.
/// 2. In the background, the resume is tried once more after a short wait (`InterruptionResumeRetrier`, which gives
///    up if the listener took over or the app was suspended past the window).
/// 3. When it still fails, the banner has a Resume button that stays until the listener acts, not an error with no action.
///
/// The orchestration lives here, not in the app model, so a host test can make the engine throw.
@MainActor
public final class MarginReturnResume {
    public enum Outcome: Equatable, Sendable {
        /// The first attempt resumed the source.
        case resumed
        /// The first attempt failed in the background and the retry resumed it.
        case resumedOnRetry
        /// The source stays paused and the listener is offered a Resume button.
        case needsListener(reason: String, retried: Bool)
        /// The retry did not run: the listener took over, or the app was suspended past the retry window.
        case abandoned
    }

    /// One retry, after a wait long enough for iOS to let go of the session and short enough that the listener has not
    /// reached for the phone.
    public static let retryDelaysMs = [1_500]

    public static let failedKind = "resume.failed"
    public static let retriedKind = "resume.retried"

    private let retrier: InterruptionResumeRetrier

    public init(retrier: InterruptionResumeRetrier = InterruptionResumeRetrier(delaysMs: MarginReturnResume.retryDelaysMs)) {
        self.retrier = retrier
    }

    public var isRetrying: Bool { retrier.isRetrying }

    /// Drops a retry still waiting (the listener or a new Margin took over).
    public func cancel() { retrier.cancel() }

    /// Returns once a running retry has finished or been cancelled. For tests.
    public func waitUntilIdle() async { await retrier.waitUntilIdle() }

    /// Tries to resume the source now.
    /// - Parameters:
    ///   - appIsInBackground: whether iOS has the app in the background (a locked screen counts). Only then is a retry made.
    ///   - stillWaiting: true while the source is still paused where the Margin left it and nothing else has taken the
    ///     listener's attention (another Margin, a recording, a seek, the listener pressing play).
    ///   - attempt: resumes the source; throws when it can't.
    ///   - record: writes a playback event.
    ///   - finished: told the outcome once, after the last attempt.
    public func resume(
        appIsInBackground: Bool,
        stillWaiting: @escaping @MainActor () -> Bool,
        attempt: @escaping @MainActor () throws -> Void,
        record: @escaping @MainActor (_ kind: String, _ fields: [String: String]) -> Void,
        finished: @escaping @MainActor (Outcome) -> Void
    ) {
        retrier.cancel()
        do {
            try attempt()
            finished(.resumed)
        } catch {
            record(Self.failedKind, Self.failureFields(error, appIsInBackground: appIsInBackground, willRetry: appIsInBackground))
            guard appIsInBackground else {
                finished(.needsListener(reason: SafeErrorText.describe(error), retried: false))
                return
            }
            retrier.begin(after: error, stillWaiting: stillWaiting, attempt: attempt) { outcome in
                switch outcome {
                case .resumed(let attempt):
                    record(Self.retriedKind, ["outcome": "resumed", "attempt": String(attempt)])
                    finished(.resumedOnRetry)
                case .retryFailed(let attempt, let reason):
                    record(Self.retriedKind, ["outcome": "failed", "attempt": String(attempt), "error": reason])
                case .gaveUp(let attempts, let reason):
                    record(Self.retriedKind, ["outcome": "gave_up", "attempt": String(attempts), "error": reason])
                    finished(.needsListener(reason: reason, retried: true))
                case .abandoned(let attempts):
                    record(Self.retriedKind, ["outcome": "abandoned", "attempt": String(attempts)])
                    finished(.abandoned)
                }
            }
        }
    }

    /// What goes in the playback events for a failed resume: the error's type and domain/code and what kind of text the
    /// listener would have been shown. Never the message itself (#3548), which can name a file or a title.
    public static func failureFields(_ error: Error, appIsInBackground: Bool, willRetry: Bool) -> [String: String] {
        [
            "errorType": typeName(error),
            "error": SafeErrorText.describe(error),
            "textClass": textClass(error),
            "appState": appIsInBackground ? "background" : "foreground",
            "willRetry": String(willRetry),
        ]
    }

    /// `plain` when the listener's line would be the error's own sentence, `generic` when it would be the stock
    /// "Something went wrong" because the text looks like code or a dump.
    static func textClass(_ error: Error) -> String {
        ListenerErrorText.message(for: error) == ListenerErrorText.fallback ? "generic" : "plain"
    }

    /// The error's Swift type name, such as `SessionKitError` or `NSError`. A type name is code, not content;
    /// anything outside identifier characters leaves as `other`.
    static func typeName(_ error: Error) -> String {
        let name = String(describing: type(of: error))
        let allowed = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        return allowed && name.count <= 96 ? name : "other"
    }
}
