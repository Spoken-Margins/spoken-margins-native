import Foundation

/// C3: how long a Spoken Margins Live Activity may stay on screen once listening stops.
///
/// Testers took a Live Activity that outlived playback for a broken app. These rules keep it honest:
/// - While listening or recording, the activity has no stale date, so playback publishes nothing extra.
/// - While paused, it carries a stale date at the idle deadline and is ended once the deadline passes.
/// - When an audio interruption ends without permission to resume (another app kept the audio), a
///   paused activity ends at once. An ordinary interruption such as a phone call only pauses, so the
///   activity stays and the listener can resume afterwards.
/// - Once ended, it stays ended until listening resumes; a later paused refresh doesn't bring it back.
public struct LiveActivityLifecycle: Equatable, Sendable {
    /// Thirty minutes covers a coffee break or a phone call, and is short enough that a listener
    /// who has moved on doesn't find a paused card on the Lock Screen for the rest of the day.
    public static let pausedIdleLimit: TimeInterval = 30 * 60

    public enum EndReason: String, Equatable, Sendable {
        case idleLimit = "idle_limit"
        case interruptionWithoutResume = "interruption_without_resume"
    }

    public enum Decision: Equatable, Sendable {
        /// Show or update the activity. `staleDate` is nil while listening.
        case show(staleDate: Date?)
        /// End the activity now.
        case end(EndReason)
        /// Already ended for this pause: don't publish, or the activity would come back.
        case hidden(EndReason)
    }

    private var pausedSessionId: String?
    private var pausedSince: Date?
    private var endReason: EndReason?

    public init() {}

    /// When the paused activity should end, if it is paused and still showing.
    public var idleDeadline: Date? {
        guard endReason == nil, let pausedSince else { return nil }
        return pausedSince.addingTimeInterval(Self.pausedIdleLimit)
    }

    /// Call for every state the Live Activity would publish.
    /// - Parameters:
    ///   - isListening: playing, starting, or recording a Margin.
    ///   - isPaused: the session is paused and not recording.
    public mutating func observe(sessionId: String?, isListening: Bool, isPaused: Bool, now: Date) -> Decision {
        guard let sessionId, !isListening, isPaused else {
            reset()
            return .show(staleDate: nil)
        }
        if pausedSessionId != sessionId || pausedSince == nil {
            pausedSessionId = sessionId
            pausedSince = now
            endReason = nil
        }
        if let endReason {
            return .hidden(endReason)
        }
        guard let deadline = idleDeadline else { return .show(staleDate: nil) }
        if now >= deadline {
            endReason = .idleLimit
            return .end(.idleLimit)
        }
        return .show(staleDate: deadline)
    }

    /// Call when `AVAudioSession` reports that an interruption ended. Returns `.end` when a paused
    /// activity should go now, or nil when nothing changes.
    public mutating func audioInterruptionEnded(shouldResume: Bool) -> Decision? {
        guard !shouldResume, pausedSessionId != nil, endReason == nil else { return nil }
        endReason = .interruptionWithoutResume
        return .end(.interruptionWithoutResume)
    }

    private mutating func reset() {
        pausedSessionId = nil
        pausedSince = nil
        endReason = nil
    }
}
