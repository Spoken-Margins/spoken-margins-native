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
/// Timing alone let one through (#2182): on a hands-free Bluetooth recording a phantom `play` came 2.2 s in. On that
/// profile the listener's own stem presses never reach the app as media commands (the owner's stem-press test logged
/// none), so a bare `play` there is the profile's noise at any time and never ends the Margin. A `pause`, the
/// play/pause toggle and skip forward still end it, and so does `play` on every other route (wired headsets, the
/// Lock Screen without a hands-free input). The cost: while recording the Lock Screen card shows a play button, so on
/// a hands-free headset that button no longer ends the Margin; the Live Activity's Finish and the app still do.
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
        case barePlayOnHandsFree = "bare_play_on_hands_free"
    }

    /// After a recording begins. Bluetooth routes take over a second to settle (`MarginCaptureTimings.startGraceMs`);
    /// the two phantom commands came 0.05 s and 0.44 s after the recorder started.
    public static let startGraceMs = 1_500
    /// After the audio route changes while recording: the headset can announce its new profile with a command.
    public static let routeChangeGraceMs = 1_000

    /// `command` is what arrived (it only matters for `play`). `recordingMs` is how long the Margin has been
    /// recording. `sinceRouteChangeMs` is how long ago the audio route last changed during this recording, nil when
    /// it has not. `onHandsFreeProfile` is whether the recording input is a Bluetooth hands-free port.
    public static func verdict(
        command: CompactControlCommand = .togglePlayPause,
        recordingMs: Int,
        sinceRouteChangeMs: Int?,
        onHandsFreeProfile: Bool = false
    ) -> Verdict {
        if recordingMs < startGraceMs { return .ignore(.recordingJustStarted) }
        if let sinceRouteChangeMs, sinceRouteChangeMs < routeChangeGraceMs { return .ignore(.routeJustChanged) }
        if onHandsFreeProfile, command == .play { return .ignore(.barePlayOnHandsFree) }
        return .endMargin
    }
}
