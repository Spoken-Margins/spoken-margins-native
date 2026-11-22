import Foundation

/// What a retry of a refused resume after an interruption may still do to a podcast (#2183, #4846). Kept out of
/// `Gate1AppModel` so it is host-tested.
///
/// "The listener has taken over" is read from the engine's count of the listener's transport commands, never from the
/// place: a refused first resume has already stepped the source back without publishing it, opening a written Margin
/// publishes that place, and a listener's Play then Pause before the player confirms, or a skip to the chapter start,
/// can land on the same place. Reading it from the place went wrong twice (audits of #4861).
@MainActor
public struct InterruptionRetryPlace {
    private let sessionId: String?
    private let targetId: String?
    private let pausedAtMs: Int?
    private let epoch: Int
    private let engine: SessionEngine

    /// Call right after the refused resume, while `snapshot` is still the paused place.
    public init(snapshot: SessionSnapshot, engine: SessionEngine) {
        sessionId = snapshot.sessionId
        targetId = snapshot.targetId
        pausedAtMs = snapshot.currentMediaTimeMs
        epoch = engine.listenerTransportEpoch
        self.engine = engine
    }

    private func isSameSourcePaused(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.status == .paused && snapshot.sessionId == sessionId && snapshot.targetId == targetId
            && !snapshot.isRecording
    }

    /// The retrier's `stillWaiting`: paused where it paused, with nothing recording.
    public func stillWaiting(_ snapshot: SessionSnapshot) -> Bool {
        isSameSourcePaused(snapshot) && snapshot.currentMediaTimeMs == pausedAtMs
    }

    /// The retrier's `handOver` precondition: the same source, still paused, and no transport command by the listener
    /// since the refusal.
    public func mayHandOverToWrittenCapture(_ snapshot: SessionSnapshot) -> Bool {
        isSameSourcePaused(snapshot) && engine.listenerTransportEpoch == epoch
    }
}
