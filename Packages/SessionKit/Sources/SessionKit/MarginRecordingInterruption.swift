import Foundation

/// Something that stopped a spoken Margin while it recorded (#771).
public enum MarginRecordingInterruptionEvent: Equatable, Sendable {
    /// A call, Siri or another app took the audio session. iOS stops the recorder.
    case interruptionBegan
    /// That interruption is over, with what iOS said about it.
    case interruptionEnded(InterruptionEnd)
    /// The route in use went away: AirPods taken out, a headset unplugged.
    case routeLost
}

public enum MarginRecordingInterruptionAction: Equatable, Sendable {
    case none
    /// Save what was recorded, marked cut short. The source stays paused for now.
    case saveCutShort
    /// Too little was recorded to keep. The source stays paused for now.
    case discard
    /// The interruption that ended a Margin is over and iOS says audio may resume.
    case resumeSource
}

/// Where an interrupted Margin left the source: the session, the item part, the position, and how
/// many Margins it has. A resume after a call fires only while all of these are unchanged, so a
/// listener who opened another session, played, skipped or recorded again during the call keeps
/// what they chose (Codex audit P2 on f11032e).
public struct InterruptedSourceMark: Equatable, Sendable {
    public var sessionId: String?
    public var targetId: String?
    public var mediaTimeMs: Int?
    public var textStart: Int?
    public var marginCount: Int

    public init(_ snapshot: SessionSnapshot) {
        sessionId = snapshot.sessionId
        targetId = snapshot.targetId
        mediaTimeMs = snapshot.currentMediaTimeMs
        textStart = snapshot.currentTextStart
        marginCount = snapshot.activeInterjectionCount
    }

    /// The mark of a source paused part-way, or nil for one that is playing, recording, or
    /// finished (#142): those are left alone.
    public static func paused(in snapshot: SessionSnapshot) -> InterruptedSourceMark? {
        guard snapshot.status == .paused, snapshot.phase != .finished, !snapshot.isRecording else { return nil }
        return InterruptedSourceMark(snapshot)
    }
}

/// Decides what an interruption does to a spoken Margin, and later whether the source resumes.
///
/// A Margin stopped by a call or Siri is saved if there is anything worth keeping, and the source
/// waits: playing it during the call would be wrong. When the call ends with "should resume", the
/// source plays on, as Save & resume would have done, if it is still where the Margin left it.
/// Lost headphones save and leave the source paused, so it never plays from the speaker, even when
/// they go during the call.
public struct MarginRecordingInterruptionPolicy: Equatable, Sendable {
    /// Less than this is a stray start, not a Margin.
    public static let minimumSecondsToKeep: TimeInterval = 1

    /// Whether the source resumes when the call ends is decided by `InterruptedCaptureResume` (#3144).
    private var callResume = InterruptedCaptureResume()

    public init() {}

    /// - Parameters:
    ///   - recordedSeconds: how long the Margin has been recording, or nil when none is.
    ///   - pausedSource: `InterruptedSourceMark.paused(in:)` for the current snapshot.
    public mutating func handle(
        _ event: MarginRecordingInterruptionEvent,
        recordedSeconds: TimeInterval?,
        pausedSource: InterruptedSourceMark?
    ) -> MarginRecordingInterruptionAction {
        switch event {
        case .interruptionBegan:
            // A later interruption with no Margin recording replaces the one whose end never came.
            guard let recordedSeconds else {
                callResume.cancel()
                return .none
            }
            callResume.marginCutShort()
            return Self.keeps(recordedSeconds) ? .saveCutShort : .discard
        case .routeLost:
            // Lost headphones cancel a resume still waiting on a call, recording or not.
            callResume.cancel()
            guard let recordedSeconds else { return .none }
            return Self.keeps(recordedSeconds) ? .saveCutShort : .discard
        case .interruptionEnded(let end):
            return callResume.ended(end, recordedSeconds: recordedSeconds, pausedSource: pausedSource)
                ? .resumeSource : .none
        }
    }

    /// Records where the save or discard left the source, so the call's end resumes only that.
    public mutating func sourceSettled(at mark: InterruptedSourceMark?) {
        callResume.sourceSettled(at: mark)
    }

    static func keeps(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= minimumSecondsToKeep
    }
}

/// A recorder that reports interruptions while it records. `recordedSeconds` is how long it had
/// been recording when the event came.
public protocol RecordingInterruptionReporting: AnyObject {
    var onInterruption: (@Sendable (_ event: MarginRecordingInterruptionEvent, _ recordedSeconds: TimeInterval?) -> Void)? { get set }
}
