import Foundation

/// Where a podcast sits while its refused resume after an interruption is retried, and whether a retry may still act on
/// it (#2183, #4846). Kept out of `Gate1AppModel` so it is host-tested.
///
/// A refused first resume has already stepped the source back (`resumePlaybackAfterInterruption`) without publishing
/// it, so the source is at one of two places: where it paused, or where the refused resume moved it. Opening a written
/// Margin publishes the second. A seek or skip by the listener moves it to a third, and then the item is theirs.
@MainActor
public struct InterruptionRetryPlace {
    private let sessionId: String?
    private let targetId: String?
    private let places: [Int?]

    /// Call right after the refused resume: `snapshot` is still the paused place, the engine's session the stepped-back one.
    public init(snapshot: SessionSnapshot, engine: SessionEngine) {
        sessionId = snapshot.sessionId
        targetId = snapshot.targetId
        places = [snapshot.currentMediaTimeMs, engine.currentSession?.position.mediaTimeMs]
    }

    private func isSameSourceAtOurPlace(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.status == .paused && snapshot.sessionId == sessionId && snapshot.targetId == targetId
            && !snapshot.isRecording
    }

    /// The retrier's `stillWaiting`: paused where it paused, with nothing recording.
    public func stillWaiting(_ snapshot: SessionSnapshot) -> Bool {
        isSameSourceAtOurPlace(snapshot) && snapshot.currentMediaTimeMs == places[0]
    }

    /// The retrier's `handOver` precondition: the same source, at the place it paused or the place the refused resume
    /// stepped it back to, so a seek, skip, Play or Pause by the listener keeps it theirs.
    public func mayHandOverToWrittenCapture(_ snapshot: SessionSnapshot) -> Bool {
        isSameSourceAtOurPlace(snapshot) && places.contains(snapshot.currentMediaTimeMs)
    }
}
