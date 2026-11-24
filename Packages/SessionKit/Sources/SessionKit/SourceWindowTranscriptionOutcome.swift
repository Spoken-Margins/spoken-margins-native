import Foundation

/// #4715: how a spoken Margin's source-window transcription ended, and so what happens to its Margin and to the audio it
/// read. The audit on #5124 found the hold treated as a failure: the heard audio around a streamed Margin was deleted and
/// the Margin marked unavailable, so the retry Allow ran had nothing left to transcribe.
public enum SourceWindowTranscriptionOutcome: Equatable, Sendable {
    /// Words came back: the Margin's context is saved and the audio has done its job.
    case completed
    /// A real failure, or no speech: the Margin's context is unavailable and the audio goes.
    case unavailable
    /// The Speech Recognition hold stopped it: nothing was transcribed for good. The Margin stays pending, the audio is
    /// kept for the retry Allow runs, and no warning is shown.
    case waitingForAnswer

    /// Any piece held wins over words from the others: the retry transcribes the whole window again, so a context is never
    /// saved from part of it.
    public init(hasWords: Bool, held: Bool) {
        if held {
            self = .waitingForAnswer
        } else {
            self = hasWords ? .completed : .unavailable
        }
    }

    /// Whether the audio the transcription read is kept for a retry rather than deleted.
    public var keepsAudio: Bool { self == .waitingForAnswer }
}
