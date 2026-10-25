import Foundation

/// The soft two-note cue that says the microphone is really capturing, so the listener can start speaking
/// without guessing through a slow (Bluetooth) startup (#1594).
///
/// Built in memory as 16-bit mono WAV, like the playback start chime, so the app ships no sound file.
/// It falls from A5 to E5, the reverse of the playback start chime's rise, so the two never sound alike.
public enum MarginReadyCue {
    public static let sampleRate = 22_050
    /// A short "ba-dum": a quick high note, then a slightly longer lower one, each faded in and out.
    public static let notes: [(frequency: Double, seconds: Double)] = [(880.0, 0.07), (659.25, 0.11)]
    public static let peak = 0.3
    /// The player's volume on the phone's speaker. Below full so a phone microphone that hears its own speaker hears little of it.
    public static let volume: Float = 0.6
    /// The player's volume with headphones on (#2594). The speaker level is right for the speaker, but headphones put the cue
    /// next to the ear, and Bluetooth's call profile plays it louder than the media volume the listener set.
    /// About 10 dB below the speaker level.
    public static let headphoneVolume: Float = 0.2

    /// The volume for the current output route.
    public static func volume(for route: ReadyCueOutputRoute) -> Float {
        route == .headphones ? headphoneVolume : volume
    }

    public static var totalSeconds: Double { notes.map(\.seconds).reduce(0, +) }

    public static func wavData() -> Data {
        var samples: [Int16] = []
        for note in notes {
            let count = Int(Double(sampleRate) * note.seconds)
            let fade = max(1, count / 5)
            for index in 0..<count {
                let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
                let value = sin(2 * .pi * note.frequency * Double(index) / Double(sampleRate)) * envelope * peak
                samples.append(Int16((value * Double(Int16.max)).rounded()))
            }
        }
        return PlaybackCueWave.wavData(samples: samples, sampleRate: sampleRate)
    }
}

/// How long the recorder is held still while the ready cue plays (#1594).
///
/// On the built-in speaker the recorder would hear the cue, and nothing removes it (no echo cancellation), so the
/// cue would be the first thing in the saved Margin. The recorder is paused just before the cue and listens again
/// when it is over. The file is written once, as before: nothing is decoded, trimmed or rewritten at save. The
/// listener speaks after hearing the cue, so no words are lost.
public enum MarginReadyCueHold {
    /// Slack after the cue for the speaker's output delay, the microphone's input delay and the cue's decay in the room.
    public static let tailSeconds = 0.06

    /// From the moment the cue starts to the moment the recorder listens again.
    public static var seconds: Double { MarginReadyCue.totalSeconds + tailSeconds }
}

/// Decides when the ready cue sounds: once per recording, and only after the recorder has really taken
/// audio in (#1594).
///
/// Pure: the watcher feeds it each poll's health. The cue never sounds on the tap, on a permission grant,
/// or because the recorder accepted its start. A capture that fails, stalls or is cancelled before audio
/// arrives gets no cue, and a capture that later stalls and recovers or restarts does not get a second one.
public struct MarginReadyCueGate: Equatable, Sendable {
    public private(set) var hasCued = false

    public init() {}

    /// True exactly once: at the first poll where the health is `.capturing` and the recorder has really
    /// reported at least `MarginCaptureTimings.firstAudioMs` of audio. A nil-reading recorder (a test double,
    /// the watch) says nothing about audio and so never cues.
    public mutating func shouldCue(health: MarginCaptureSupervisor.Health, capturedMs: Int) -> Bool {
        guard !hasCued, health == .capturing, capturedMs >= MarginCaptureTimings.firstAudioMs else { return false }
        hasCued = true
        return true
    }
}

/// Where the ready cue is heard (#2594). The speaker keeps its level; anything worn on or in the ears is quieter.
public enum ReadyCueOutputRoute: Equatable, Sendable {
    case speaker
    case headphones

    /// AVAudioSession port types, as their raw strings, that put the sound at the ear. USB audio is included: on a phone it is
    /// a headset or a dongle. Everything else (the built-in speaker, the receiver, AirPlay, a car, a line out) and an empty
    /// route keep the speaker level, so a route not listed here behaves exactly as before.
    private static let headphonePorts: Set<String> = ["BluetoothHFP", "BluetoothA2DPOutput", "BluetoothLE", "Headphones", "USBAudio"]

    /// `headphones` when any output is worn on the ears.
    public init(outputPortTypes: [String]) {
        self = outputPortTypes.contains(where: Self.headphonePorts.contains) ? .headphones : .speaker
    }
}
