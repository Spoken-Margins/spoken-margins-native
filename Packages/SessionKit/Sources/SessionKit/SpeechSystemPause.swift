import Foundation

/// What came of a resume an ended interruption asked for (#538). Logged after the attempt, so a
/// device report doesn't read a request as a resume when the audio session then refused to start.
public enum SpeechInterruptionResume: Equatable, Sendable {
    case resumed
    /// Nothing was paused for the interruption by the time it ended, so nothing resumed.
    case skipped
    case failed(reason: String)

    public var kind: String { "speech.interruption_resume" }

    public var fields: [String: String] {
        switch self {
        case .resumed: ["outcome": "resumed"]
        case .skipped: ["outcome": "skipped"]
        case .failed(let reason): ["outcome": "failed", "error": reason]
        }
    }

    /// The value the app's `speechPlaybackInterruption` diagnostic has always shown.
    public var diagnostic: String {
        switch self {
        case .resumed: "resumed"
        case .skipped: "resume_skipped"
        case .failed(let reason): "resume_failed:\(reason)"
        }
    }
}

/// Holds an interruption's resume until playback settles (#538). `resumePlayback()` can return a
/// starting snapshot while text audio is still rendering, or a failed one, without throwing, so the
/// outcome is the status playback reaches for that session, not the call returning.
public struct SpeechInterruptionResumeWatch: Equatable, Sendable {
    private var startingSessionId: String??

    public init() {}

    /// The outcome once `resumePlayback()` returned `snapshot`, or nil while it is still starting.
    public mutating func resumeReturned(_ snapshot: SessionSnapshot) -> SpeechInterruptionResume? {
        startingSessionId = snapshot.status == .starting ? .some(snapshot.sessionId) : nil
        return startingSessionId == nil ? Self.outcome(of: snapshot) : nil
    }

    /// The held outcome once a starting resume settles: nil when none is held or it is still starting.
    public mutating func snapshotChanged(_ snapshot: SessionSnapshot) -> SpeechInterruptionResume? {
        guard let sessionId = startingSessionId else { return nil }
        if snapshot.sessionId == sessionId, snapshot.status == .starting { return nil }
        startingSessionId = nil
        guard snapshot.sessionId == sessionId else { return .failed(reason: "replaced_before_start") }
        return Self.outcome(of: snapshot)
    }

    private static func outcome(of snapshot: SessionSnapshot) -> SpeechInterruptionResume {
        switch snapshot.status {
        case .playing: .resumed
        case .failed: .failed(reason: snapshot.lastFailure ?? "playback_failed")
        case let other: .failed(reason: "ended_\(other.rawValue)")
        }
    }
}
