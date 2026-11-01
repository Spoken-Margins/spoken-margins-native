import Foundation

/// The engine's "a start is pending, which attempt, until when" state, in one value (#3032 slice 4).
///
/// A start is a request to the audio client that is confirmed, fails, or is still pending. The engine used to keep six
/// loose fields for it (the attempt counter, the active attempt, the pending attempt and target, the deadline and the
/// first-pending time), set and cleared at about 17 sites, so a resume after a Margin, a call or a relaunch could leave a
/// half-cleared start behind and a start that was already confirmed could be treated as pending. Now the engine reports a
/// start request (`begin`), what the client says (`confirmed`, `failed`, `observePending`) and obeys the answer.
public struct PlaybackStartAttempt: Equatable, Sendable {
    /// What a pending start looks like after the client was asked again.
    public enum PendingVerdict: Equatable, Sendable {
        /// Still waiting. Either the start is new, the deadline has not passed, or the client is still rendering audio.
        case waiting
        /// The deadline passed and the render allowance, if any, is spent: the engine should recover or fail the start.
        case expired
    }

    private let timeout: TimeInterval
    private var latestAttemptId = 0
    private var activeAttemptId: Int?
    private var pendingAttemptId: Int?
    private var pendingTargetId: String?
    private var deadline: Date?
    private var firstPendingAt: Date?

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// The longest a start may keep waiting for audio that is still rendering, however often its deadline is extended (#235).
    private var waitCap: TimeInterval { timeout * 4 }

    /// The attempt the engine is polling: the active one, or the latest when none is active (a start already settled).
    public var currentAttemptId: Int { activeAttemptId ?? latestAttemptId }

    /// A new start was requested: a fresh attempt id, which is the active one until the start settles.
    @discardableResult
    public mutating func begin() -> Int {
        latestAttemptId += 1
        activeAttemptId = latestAttemptId
        return latestAttemptId
    }

    /// The client confirmed the start. Nothing is pending any more.
    public mutating func confirmed() { clear() }

    /// The start failed and was not recovered. Nothing is pending any more.
    public mutating func failed() { clear() }

    /// Drops the pending state (the status left `.starting`, or the session ended). The attempt counter keeps counting,
    /// so a stale id from an earlier start never equals a later one.
    public mutating func clear() {
        activeAttemptId = nil
        pendingAttemptId = nil
        pendingTargetId = nil
        deadline = nil
        firstPendingAt = nil
    }

    /// Whether the start's deadline has passed. False when no start is pending.
    public func expired(now: Date) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    /// The client still reports `targetId` as pending for `attemptId`. A different target or attempt than the one already
    /// pending is a new wait that starts a fresh deadline. An old wait past its deadline is `expired`, unless the client is
    /// still rendering audio and the wait cap has not passed, which extends the deadline instead.
    public mutating func observePending(
        targetId: String, attemptId: Int, now: Date, awaitingRenderedAudio: () -> Bool
    ) -> PendingVerdict {
        if pendingTargetId != targetId || pendingAttemptId != attemptId {
            pendingTargetId = targetId
            pendingAttemptId = attemptId
            deadline = now.addingTimeInterval(timeout)
            firstPendingAt = now
            return .waiting
        }
        guard expired(now: now) else { return .waiting }
        // A slow on-device render isn't a stalled start: the client's own render deadline and fallback cover it.
        if awaitingRenderedAudio(), now.timeIntervalSince(firstPendingAt ?? now) < waitCap {
            deadline = now.addingTimeInterval(timeout)
            return .waiting
        }
        return .expired
    }

    /// The engine restarted the same attempt's transport (a remote stream recreated once): wait again with a new deadline.
    /// The time the attempt first started waiting is kept, so the wait cap still counts from the original start.
    public mutating func restarted(targetId: String, attemptId: Int, now: Date) {
        pendingTargetId = targetId
        pendingAttemptId = attemptId
        deadline = now.addingTimeInterval(timeout)
    }

    /// The engine moved the attempt to another target (narration replaced by live speech): forget the old wait so the new
    /// target's first pending observation starts its own deadline.
    public mutating func movedToAnotherTarget() {
        pendingTargetId = nil
        pendingAttemptId = nil
        deadline = nil
    }
}
