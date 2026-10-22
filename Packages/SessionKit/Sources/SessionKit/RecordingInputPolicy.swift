import Foundation

/// Which microphone Add a Margin opens (#1506).
///
/// Headphones playing over Bluetooth are on A2DP, the music profile, which has no microphone. Allowing the
/// headset microphone (HFP) makes iOS move the headphones to the hands-free profile first: more than a second
/// in the owner's Diagnostics, with the headphones dipping to phone-call sound quality until it's over.
/// Recording from the phone's own microphone leaves the headphones on A2DP, so capture starts as soon as the
/// recorder does. The cost is a microphone that is further from the listener's mouth.
public enum RecordingInputChoice: String, Equatable, Sendable {
    /// The headphones stay on A2DP and the phone's microphone records.
    case phoneMicrophoneKeepingA2DP = "phone_microphone_a2dp_kept"
    /// The headset's microphone may be used, as before. iOS decides.
    case headsetMicrophoneAllowed = "headset_microphone_allowed"
}

public enum RecordingInputPolicy {
    /// Whether Margins on A2DP headphones may record from the phone's microphone. Off: on 2026-10-13 the owner chose
    /// the headphone microphone over the shorter wait (#1506, docs/solid-ground-phone-validation.md).
    /// Turning it on takes the owner's word again, then this one value and the pinned test.
    public static let phoneMicrophoneOnA2DPAllowed = false

    /// `outputPortTypes` are the raw values of the audio session's current output ports (`AVAudioSession.Port`),
    /// read before the session is reconfigured for recording.
    ///
    /// The phone's microphone is chosen only when the listener is on A2DP and not already on the hands-free
    /// profile (a call, or another app holding the headset microphone): there the switch is free or already paid,
    /// and the headset microphone is the better one to use. Every other route keeps the earlier behavior.
    public static func choice(outputPortTypes: [String], phoneMicrophoneAllowed: Bool = phoneMicrophoneOnA2DPAllowed) -> RecordingInputChoice {
        guard phoneMicrophoneAllowed else { return .headsetMicrophoneAllowed }
        let onA2DP = outputPortTypes.contains(Port.bluetoothA2DP)
        let onHandsFree = outputPortTypes.contains(Port.bluetoothHandsFree)
        return onA2DP && !onHandsFree ? .phoneMicrophoneKeepingA2DP : .headsetMicrophoneAllowed
    }

    enum Port {
        static let bluetoothA2DP = "BluetoothA2DPOutput"
        static let bluetoothHandsFree = "BluetoothHFP"
    }
}
