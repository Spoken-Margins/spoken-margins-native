import Foundation

/// Ends a Margin from a headphone press when iOS delivers that press as the headset's mute gesture.
///
/// With the microphone open, Bluetooth headphones are in call mode. A press is then the mute gesture: iOS zeroes
/// the app's input and posts `AVAudioApplication.inputMuteStateChangeNotification` (iOS 17 and later, only while
/// a record session is active). It is the "ba-dump" the owner hears (2026-10-30). The app cannot intercept it:
/// `setInputMuteStateChangeHandler` is macOS-only. So the notification is the one signal there is.
///
/// Rule, owner call 2026-11-07: a press that changes the mute state ends and saves the Margin that is recording.
/// He has never been muted by accident and accepts the risk of a stray trigger; the Margin's words are kept.
/// - A notification that repeats the current state is not a press (the system re-sends the stored state when a
///   record session goes active), so it is ignored.
/// - Nothing counts in the first moment of a recording or just after the audio route changed: the headset's profile
///   switch is noisy then (#1708, #2182), the same windows as `RecordingTransportGuard`.
///
/// Whether iOS posts the notification for a press on the owner's headset is unverified until a device log shows it
/// (#3650); the app logs every event, ignored ones included.
///
/// Pure: the app passes milliseconds on a clock that only moves forward.
public struct HeadphoneMuteGestureDetector: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// The listener pressed the headset: finish and save the Margin.
        case endMargin
        case ignore(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case recordingJustStarted = "recording_just_started"
        case routeJustChanged = "route_just_changed"
        /// The notification repeated the state the microphone was already in.
        case noChange = "no_change"
    }

    private var muted: Bool

    /// `initiallyMuted` is the app's input mute state when the Margin began recording.
    public init(initiallyMuted: Bool) {
        muted = initiallyMuted
    }

    /// The mute state the detector last saw.
    public var isMuted: Bool { muted }

    public mutating func observe(muted newState: Bool, recordingMs: Int, sinceRouteChangeMs: Int?) -> Verdict {
        let changed = newState != muted
        muted = newState
        if recordingMs < RecordingTransportGuard.startGraceMs { return .ignore(.recordingJustStarted) }
        if let sinceRouteChangeMs, sinceRouteChangeMs < RecordingTransportGuard.routeChangeGraceMs {
            return .ignore(.routeJustChanged)
        }
        return changed ? .endMargin : .ignore(.noChange)
    }
}
