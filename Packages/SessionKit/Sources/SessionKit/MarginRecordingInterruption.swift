import Foundation

/// Something that stopped a spoken Margin while it recorded (#771).
public enum MarginRecordingInterruptionEvent: Equatable, Sendable {
    /// A call, Siri or another app took the audio session. iOS stops the recorder.
    case interruptionBegan
    /// That interruption is over. `shouldResume` is iOS saying audio may start again.
    case interruptionEnded(shouldResume: Bool)
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

/// Decides what an interruption does to a spoken Margin, and later whether the source resumes.
///
/// A Margin stopped by a call or Siri is saved if there is anything worth keeping, and the source
/// waits: playing it during the call would be wrong. When the call ends with "should resume", the
/// source plays on, as Save & resume would have done. Lost headphones save and leave the source
/// paused, so it never plays from the speaker.
public struct MarginRecordingInterruptionPolicy: Equatable, Sendable {
    /// Less than this is a stray start, not a Margin.
    public static let minimumSecondsToKeep: TimeInterval = 1

    private var resumesWhenInterruptionEnds = false

    public init() {}

    /// - Parameters:
    ///   - recordedSeconds: how long the Margin has been recording, or nil when none is.
    ///   - sourceIsPaused: whether the source is paused now; a source the listener already
    ///     restarted is left alone.
    public mutating func handle(
        _ event: MarginRecordingInterruptionEvent,
        recordedSeconds: TimeInterval?,
        sourceIsPaused: Bool
    ) -> MarginRecordingInterruptionAction {
        switch event {
        case .interruptionBegan:
            guard let recordedSeconds else {
                resumesWhenInterruptionEnds = false
                return .none
            }
            resumesWhenInterruptionEnds = true
            return Self.keeps(recordedSeconds) ? .saveCutShort : .discard
        case .routeLost:
            guard let recordedSeconds else { return .none }
            resumesWhenInterruptionEnds = false
            return Self.keeps(recordedSeconds) ? .saveCutShort : .discard
        case .interruptionEnded(let shouldResume):
            defer { resumesWhenInterruptionEnds = false }
            guard resumesWhenInterruptionEnds, shouldResume, recordedSeconds == nil, sourceIsPaused else { return .none }
            return .resumeSource
        }
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
