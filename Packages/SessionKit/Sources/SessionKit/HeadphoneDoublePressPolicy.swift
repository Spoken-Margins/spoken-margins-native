import Foundation

/// What a headphone double-press does while nothing is recording (#2031). Stored as a raw string in
/// UserDefaults under `storageKey`, never in the database, so older builds are unaffected.
public enum HeadphoneDoublePressAction: String, CaseIterable, Equatable, Sendable {
    case addMargin
    case skipForward

    public static let storageKey = "headphoneDoublePressAction"
    public static let `default`: HeadphoneDoublePressAction = .addMargin

    public init(storedValue: String?) {
        self = storedValue.flatMap(HeadphoneDoublePressAction.init(rawValue:)) ?? .default
    }
}

/// Which remote signal arrived. A headphone double-press is the system "next track" command; the Lock
/// Screen and on-screen skip arrow are "skip forward". `CompactControlCommand` is persisted in snapshots
/// that shipped builds read, so the distinction is carried here and in the command origin instead.
public enum HeadphoneRemoteSignal: Equatable, Sendable {
    case nextTrack
    case skipForward
    case other

    /// Appended to the origin of a command that came from the next-track remote command.
    public static let nextTrackOriginSuffix = "_next_track"

    public init(origin: String) {
        self = origin.hasSuffix(Self.nextTrackOriginSuffix) ? .nextTrack : .skipForward
    }
}

public enum HeadphoneDoublePressDecision: Equatable, Sendable {
    /// Start a Margin the way the on-screen Add a Margin does.
    case startMargin
    /// End and save the Margin that is recording.
    case endMargin
    case skipForward
    /// Not ours: handle the command as before.
    case passThrough
}

public enum HeadphoneDoublePressPolicy {
    public static func decide(
        signal: HeadphoneRemoteSignal,
        setting: HeadphoneDoublePressAction,
        isRecording: Bool
    ) -> HeadphoneDoublePressDecision {
        switch signal {
        case .other:
            return .passThrough
        case .skipForward:
            return isRecording ? .endMargin : .skipForward
        case .nextTrack:
            if isRecording { return .endMargin }
            switch setting {
            case .addMargin: return .startMargin
            case .skipForward: return .skipForward
            }
        }
    }
}
