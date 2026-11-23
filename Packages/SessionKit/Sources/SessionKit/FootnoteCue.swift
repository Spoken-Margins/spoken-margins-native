import Foundation

/// The single soft tone that tells the listener a footnote was cited, in "Chime where cited" mode (#3777).
///
/// One note (E5), so it can never be taken for the friend's two-note chime (`SharedMarginCue`) that says a
/// Margin has arrived. It starts softly, so it does not startle over narration, and fades away. Built in memory
/// as 16-bit mono WAV, so the app ships no sound file. Its level is the friend chime's (`peak`).
public enum FootnoteCue {
    public static let sampleRate = 44_100
    public static let frequency = 659.25
    public static let seconds = 0.18
    /// How long the note takes to reach full level.
    public static let attackSeconds = 0.03
    /// Peak amplitude, the same as `SharedMarginCue`'s so the two sit at one loudness.
    public static let peak = 0.30
    /// How long narration waits at a cited note in chime mode: the tone and a short gap, so the passage after the note
    /// starts after the tone has sounded and not on top of it (Design, Flow 5: "a pause of about 0.4 s").
    public static let leadIn: TimeInterval = 0.4

    public static func wavData() -> Data {
        let count = Int(Double(sampleRate) * seconds)
        let attack = max(1, Int(Double(sampleRate) * attackSeconds))
        var samples: [Int16] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            // A sine-shaped rise, then a smooth fall to silence at the last sample.
            let envelope: Double
            if index < attack {
                envelope = sin(.pi / 2 * Double(index) / Double(attack))
            } else {
                let fall = Double(index - attack) / Double(max(1, count - 1 - attack))
                envelope = cos(.pi / 2 * fall)
            }
            let value = sin(2 * .pi * frequency * Double(index) / Double(sampleRate)) * envelope * peak
            samples.append(Int16((value * Double(Int16.max)).rounded()))
        }
        return PlaybackCueWave.wavData(samples: samples, sampleRate: sampleRate)
    }
}
