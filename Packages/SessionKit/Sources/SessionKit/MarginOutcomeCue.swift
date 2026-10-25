import Foundation

/// What the listener hears when a spoken Margin ends, so a phone in a pocket says whether the Margin was kept (#1977).
///
/// Until now every ending sounded the same: the source resumed, whether the Margin was saved, saved but possibly
/// cut, thrown away as empty, or the microphone had died. The start has its own cue (`MarginReadyCue`, #1594); these
/// are the endings. They are the same family (soft sine notes, built in memory, no sound file) with different
/// shapes, so a rising pair always means "kept", a low falling note "gone", and a slow low pair "still not
/// recording":
///
/// - `saved`: a rising pair, E5 then A5. The reverse of the ready cue's falling A5 then E5.
/// - `savedMaybeCut`: the same rising pair, then a low A4 held a moment: kept, with a question.
/// - `emptyDiscarded`: one low note sliding down, B4 to E4: nothing was kept.
/// - `micStopped`: two low notes, G4 then E4, then silence to the end of a four-second period. The app loops it
///   quietly from the moment the microphone dies until the listener saves or cancels.
public enum MarginOutcomeCue: String, CaseIterable, Equatable, Sendable {
    case saved
    case savedMaybeCut = "saved_maybe_cut"
    case emptyDiscarded = "empty_discarded"
    case micStopped = "mic_stopped"

    public static let sampleRate = 22_050
    /// Below the ready cue's level: these play after the recorder has stopped, so nothing has to out-shout the room.
    public static let volume: Float = 0.5
    /// The silence-padded length of the repeating cue (`micStopped`), from the start of one repetition to the next.
    public static let micStoppedPeriod: TimeInterval = 4.0
    /// No ending cue's sound lasts this long, so none runs on into the source resuming.
    public static let maxSoundSeconds: TimeInterval = 0.7

    /// The cue for what saving the recording decided. The verdict is the supervisor's, qualified by the finished file.
    public init(verdict: MarginCaptureSupervisor.SaveVerdict) {
        switch verdict {
        case .save: self = .saved
        case .saveCutShort: self = .savedMaybeCut
        case .discardEmpty: self = .emptyDiscarded
        }
    }

    /// Plays over and over until stopped: only the dead microphone, which stays dead until the listener acts.
    public var repeats: Bool { self == .micStopped }

    private struct Note {
        var from: Double
        var to: Double
        var seconds: Double
        var peak: Double
    }

    private var notes: [Note] {
        switch self {
        case .saved:
            [Note(from: 659.25, to: 659.25, seconds: 0.07, peak: 0.3), Note(from: 880, to: 880, seconds: 0.12, peak: 0.3)]
        case .savedMaybeCut:
            [Note(from: 659.25, to: 659.25, seconds: 0.07, peak: 0.3), Note(from: 880, to: 880, seconds: 0.09, peak: 0.3),
             Note(from: 440, to: 440, seconds: 0.2, peak: 0.26)]
        case .emptyDiscarded:
            [Note(from: 493.88, to: 329.63, seconds: 0.3, peak: 0.26)]
        case .micStopped:
            [Note(from: 392, to: 392, seconds: 0.12, peak: 0.22), Note(from: 329.63, to: 329.63, seconds: 0.16, peak: 0.22)]
        }
    }

    /// How long the sound itself lasts, without the padding a repeating cue carries.
    public var soundSeconds: Double { notes.map(\.seconds).reduce(0, +) }

    /// 16-bit mono WAV. A repeating cue is a whole period long, so a looping player needs no timer.
    public func wavData() -> Data {
        var samples: [Int16] = []
        var phase = 0.0
        for note in notes {
            let count = Int(Double(Self.sampleRate) * note.seconds)
            let fade = max(1, count / 5)
            for index in 0..<count {
                let progress = Double(index) / Double(count)
                let frequency = note.from + (note.to - note.from) * progress
                phase += 2 * .pi * frequency / Double(Self.sampleRate)
                let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
                samples.append(Int16((sin(phase) * envelope * note.peak * Double(Int16.max)).rounded()))
            }
        }
        if repeats {
            let total = Int(Double(Self.sampleRate) * Self.micStoppedPeriod)
            if samples.count < total { samples += [Int16](repeating: 0, count: total - samples.count) }
        }
        return PlaybackCueWave.wavData(samples: samples, sampleRate: Self.sampleRate)
    }
}
