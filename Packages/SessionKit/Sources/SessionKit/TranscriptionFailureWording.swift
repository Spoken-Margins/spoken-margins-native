import Foundation

/// #268: what the app says when a voice Margin's transcript isn't made.
///
/// Declining Speech Recognition is the listener's choice, not an app failure, so it gets
/// its own words and says how to turn it back on. The stored `transcriptionStatus` stays
/// "failed", because Build 29 must still open the database; the reason is mapped here,
/// from the transcription error or from the current permission.
public enum TranscriptionFailureWording {
    /// The error every transcription path throws when Speech Recognition isn't allowed.
    public static let speechRecognitionOffError = "speech_recognition_not_authorized"

    /// A banner after a transcription attempt: what it says, and whether it reports a failure.
    public struct Notice: Equatable, Sendable {
        public let message: String
        public let isFailure: Bool

        /// Hands the message to the warning or the failure reporter.
        public func present(warning: (String) -> Void, failure: (String) -> Void) {
            isFailure ? failure(message) : warning(message)
        }
    }

    public static func isSpeechRecognitionOff(error: String) -> Bool {
        error.contains(speechRecognitionOffError)
    }

    /// The banner after transcribing a saved voice Margin fails. `isRetry` is a retry of a
    /// Margin that may already have words, which it keeps.
    public static func notice(error: String, isRetry: Bool) -> Notice {
        if isSpeechRecognitionOff(error: error) {
            return Notice(
                message: isRetry
                    ? "Speech Recognition is off, so the Margin wasn't transcribed again. Turn it on in Settings, then retry."
                    : "Audio saved. There's no transcript because Speech Recognition is off. Turn it on in Settings, then retry the Margin.",
                isFailure: false
            )
        }
        return Notice(
            message: isRetry
                ? "Saved audio and current transcript kept. Retranscription failed."
                : "Audio saved. Transcript failed.",
            isFailure: true
        )
    }

    /// The one line a voice Margin shows when it needs attention. Speech Recognition being off
    /// comes first: it also stops the source window being transcribed, so the context fails for
    /// the same reason, and "Context needs retry" alone would hide how to fix both.
    public static func marginAttention(
        transcriptionStatus: String,
        speechRecognitionOff: Bool,
        contextUnavailable: Bool,
        recordingMissing: Bool
    ) -> String {
        let transcript = marginStatus(transcriptionStatus: transcriptionStatus, speechRecognitionOff: speechRecognitionOff)
        if transcriptionStatus == "failed", speechRecognitionOff, let transcript { return transcript }
        if contextUnavailable { return "Context needs retry" }
        if recordingMissing { return "Recording is unavailable" }
        return transcript ?? "Margin needs attention"
    }

    /// The Margin's own status line for a transcript that isn't ready, or nil when it is.
    /// `speechRecognitionOff` is the permission now: a Margin whose transcript failed can
    /// only be transcribed once it's back on.
    public static func marginStatus(transcriptionStatus: String, speechRecognitionOff: Bool) -> String? {
        switch transcriptionStatus {
        case "failed":
            return speechRecognitionOff
                ? "No transcript: Speech Recognition is off. Turn it on in Settings."
                : "Transcription needs retry"
        case "pending":
            // Only live work is "pending": a launch settles the orphans as "failed" (#942).
            return "Transcribing…"
        default:
            return nil
        }
    }
}
