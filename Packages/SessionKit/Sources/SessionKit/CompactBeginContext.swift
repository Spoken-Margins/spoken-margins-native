import Foundation

/// What happened shortly before a Margin was started from a compact control, kept so an export can say what
/// the failed starts share (#4414). iOS refuses a background recording start in some cases and allows it in
/// others; the questions are whether the refusals follow a playback restart, a recent return to the foreground
/// or a just-ended Margin. It holds times and one command origin, never listener content.
public struct CompactBeginContext: Equatable, Sendable {
    public static let notSeen = "not_seen"

    private var backgroundedAt: Date?
    private var playbackStartedAt: Date?
    private var recordingEndedAt: Date?
    private var transportOrigin: String?

    public init() {}

    /// The app went to the background.
    public mutating func appEnteredBackground(at time: Date) {
        backgroundedAt = time
    }

    /// A playback or recording state changed. Playback started when the status became `.playing`; a recording
    /// ended when `isRecording` went from true to false.
    public mutating func snapshotChanged(from old: SessionSnapshot, to new: SessionSnapshot, at time: Date) {
        if old.status != .playing, new.status == .playing { playbackStartedAt = time }
        if old.isRecording, !new.isRecording { recordingEndedAt = time }
    }

    /// A compact command arrived. Only transport commands count: Margin commands are what the fields explain.
    public mutating func noteCommand(_ command: CompactControlCommand, origin: String) {
        switch command {
        case .beginInterjection, .finishInterjection, .cancelInterjection: return
        default: transportOrigin = CompactBeginFailureRecord.clean(origin)
        }
    }

    /// Whole seconds (rounded down) since each moment, and the last transport command's origin. A moment never
    /// seen says `not_seen`. A clock that moved backwards reads 0.
    public func fields(now: Date) -> [String: String] {
        func since(_ time: Date?) -> String {
            guard let time else { return Self.notSeen }
            return String(max(0, Int(now.timeIntervalSince(time).rounded(.down))))
        }
        return [
            "sinceBackgroundS": since(backgroundedAt),
            "sincePlaybackStartS": since(playbackStartedAt),
            "sinceRecordingEndS": since(recordingEndedAt),
            "lastTransportOrigin": transportOrigin ?? Self.notSeen
        ]
    }
}
