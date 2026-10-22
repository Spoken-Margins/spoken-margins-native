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
    /// The player's volume. Below full so a phone microphone that hears its own speaker hears little of it.
    public static let volume: Float = 0.6

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

/// How much of the start of a recording the ready cue can reach (#1594).
///
/// On the built-in speaker the recorder is running when the cue plays, with no echo cancellation, so the cue
/// bleeds into the file. The saved Margin starts after it: everything up to the cue, the cue and a short tail
/// is dropped when the recording is saved. The listener speaks only after hearing the cue, so no words go with it.
public enum MarginReadyCueTrim {
    /// Slack after the cue for the speaker's output delay, the microphone's input delay and the cue's decay in the room.
    public static let tailMs = 60

    /// Milliseconds to drop from the start of the file, given how much the recorder had taken in when the cue began.
    public static func leadingMs(cueStartedAtRecordedMs: Int) -> Int {
        max(0, cueStartedAtRecordedMs) + Int((MarginReadyCue.totalSeconds * 1_000).rounded(.up)) + tailMs
    }
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
