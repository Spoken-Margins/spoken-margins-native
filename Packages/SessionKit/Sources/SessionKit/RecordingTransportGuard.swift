import Foundation

/// Whether a play, pause or skip from Now Playing while a Margin records is the listener's click or the
/// headset's own noise (#1708).
///
/// A headphone click, car button or Lock Screen Play/Pause ends and saves the Margin (#1030). But when the
/// microphone opens, Bluetooth headphones switch from music to the hands-free profile, and the switch can send
/// the app a `play` the listener never pressed. On the owner's phone it ended the Margin 50 ms and 440 ms after
/// recording began. No listener clicks a headset that fast, so a command in the first moment, or just after the
/// audio route changed, is ignored and logged.
///
/// Pure: the app passes the milliseconds on a clock that only moves forward.
public enum RecordingTransportGuard {
    public enum Verdict: Equatable, Sendable {
        /// The listener's click: finish and save the Margin.
        case endMargin
        /// Headset noise: leave the Margin recording and log why.
        case ignore(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case recordingJustStarted = "recording_just_started"
        case routeJustChanged = "route_just_changed"
    }

    /// After a recording begins. Bluetooth routes take over a second to settle (`MarginCaptureTimings.startGraceMs`);
    /// the two phantom commands came 0.05 s and 0.44 s after the recorder started.
    public static let startGraceMs = 1_500
    /// After the audio route changes while recording: the headset can announce its new profile with a command.
    public static let routeChangeGraceMs = 1_000

    /// `recordingMs` is how long the Margin has been recording. `sinceRouteChangeMs` is how long ago the audio
    /// route last changed during this recording, nil when it has not.
    public static func verdict(recordingMs: Int, sinceRouteChangeMs: Int?) -> Verdict {
        if recordingMs < startGraceMs { return .ignore(.recordingJustStarted) }
        if let sinceRouteChangeMs, sinceRouteChangeMs < routeChangeGraceMs { return .ignore(.routeJustChanged) }
        return .endMargin
    }
}
