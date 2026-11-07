import Foundation

/// Ends a Margin from a headphone double press when iOS delivers that press as the headset's mute gesture.
///
/// With the microphone open, Bluetooth headphones are in call mode. A press is then the mute gesture: iOS zeroes
/// the app's input and posts `AVAudioApplication.inputMuteStateChangeNotification` (iOS 17 and later, only while
/// a record session is active). It is the "ba-dump" the owner hears (2026-10-30). The app cannot intercept it:
/// `setInputMuteStateChangeHandler` is macOS-only. So the notification is the one signal there is, and a double
/// press should show up as two state changes close together (muted, then unmuted).
///
/// Whether it does is not known until a device log shows it (#3650). Until then this type only decides what to do
/// with such events; the app logs every one.
///
/// Rules, owner call 2026-11-07 (single press never ends a Margin):
/// - A single state change never ends a Margin. It is remembered as the first half of a possible pair.
/// - Two real changes (the state flipped each time) within `pairWindowMs` end it.
/// - A notification that repeats the current state is not a press (the system re-sends the stored state when a
///   record session goes active), so it is ignored.
/// - Nothing counts in the first moment of a recording or just after the audio route changed: the headset's profile
///   switch is noisy then (#1708, #2182), the same windows as `RecordingTransportGuard`.
///
/// Pure: the app passes milliseconds on a clock that only moves forward.
public struct HeadphoneMuteGestureDetector: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// The listener's double press: finish and save the Margin.
        case endMargin
        /// A real change, the first of a possible pair. Not enough on its own.
        case firstOfPair
        case ignore(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case recordingJustStarted = "recording_just_started"
        case routeJustChanged = "route_just_changed"
        /// The notification repeated the state the microphone was already in.
        case noChange = "no_change"
    }

    /// The most time between the two presses of a double press, as the headset reports them.
    public static let pairWindowMs = 600

    private var muted: Bool
    private var firstChangeAtMs: Int?

    /// `initiallyMuted` is the app's input mute state when the Margin began recording.
    public init(initiallyMuted: Bool) {
        muted = initiallyMuted
    }

    /// The mute state the detector last saw.
    public var isMuted: Bool { muted }

    public mutating func observe(muted newState: Bool, recordingMs: Int, sinceRouteChangeMs: Int?, nowMs: Int) -> Verdict {
        let changed = newState != muted
        muted = newState
        if recordingMs < RecordingTransportGuard.startGraceMs {
            firstChangeAtMs = nil
            return .ignore(.recordingJustStarted)
        }
        if let sinceRouteChangeMs, sinceRouteChangeMs < RecordingTransportGuard.routeChangeGraceMs {
            firstChangeAtMs = nil
            return .ignore(.routeJustChanged)
        }
        guard changed else { return .ignore(.noChange) }
        if let first = firstChangeAtMs, nowMs - first <= Self.pairWindowMs {
            firstChangeAtMs = nil
            return .endMargin
        }
        firstChangeAtMs = nowMs
        return .firstOfPair
    }
}
