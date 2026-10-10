import Foundation

/// The waiting sound for #357: a start that is still silent about two seconds after the start chime gets three
/// soft bubble pops, repeated, until the first word, a pause or a failure. One chime and then silence reads as a
/// stall when the wait is long, and the listener may have left the app (owner check, 2026-10-06).
///
/// The sound is one WAV that is a whole period long (the pops, then silence), so the app loops it with the audio
/// player and the repetition keeps going in the background without a timer.
public enum PlaybackWaitingCue {
    /// How long after the start chime the first repetition begins.
    public static let delay: TimeInterval = 2.0
    /// From the start of one repetition to the start of the next.
    public static let period: TimeInterval = 3.0
    /// A start still silent after this long stops repeating, so a hung start doesn't sound forever.
    public static let limit: TimeInterval = 120
    public static let sampleRate = 22_050
    /// Quieter than the start chime (`PlaybackStartChime.peak`).
    public static let peak = 0.22
    /// Three pops, each a little higher than the last, 0.14 s apart.
    public static let pops: [(start: Double, frequency: Double)] = [(0, 520), (0.14, 620), (0.28, 740)]
    public static let popSeconds = 0.09

    /// One period of audio: the pops at the start, silence to the end.
    public static func wavData() -> Data {
        var samples = [Int16](repeating: 0, count: Int(Double(sampleRate) * period))
        for pop in pops {
            let first = Int(Double(sampleRate) * pop.start)
            let count = Int(Double(sampleRate) * popSeconds)
            for index in 0..<count where first + index < samples.count {
                let t = Double(index) / Double(sampleRate)
                // A bubble: the pitch rises quickly as the pop dies away. The attack is a few milliseconds so it doesn't click.
                let phase = 2 * .pi * (pop.frequency * t + 0.5 * pop.frequency * 8 * t * t)
                let attack = min(1, Double(index) / (0.004 * Double(sampleRate)))
                let tail = Double(count - 1 - index) / (0.01 * Double(sampleRate))
                let envelope = attack * min(1, tail) * exp(-t / 0.03)
                samples[first + index] = Int16((sin(phase) * envelope * peak * Double(Int16.max)).rounded())
            }
        }
        return PlaybackCueWave.wavData(samples: samples, sampleRate: sampleRate)
    }
}
