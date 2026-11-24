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

    /// The two statuses a Margins row offers a Retry beside (#3856). `MarginRowRepair` keys off these same strings, so the
    /// button can only appear beside the words it fixes.
    ///
    /// The context status names what failed in the listener's words (#4608): the app could not read the source text near the
    /// Margin. It says nothing about the Margin's own recording or words, which a failed context never touches, and it
    /// doesn't say "tap Retry", because the row shows no Retry while the Margin's own transcript is pending or a retry runs.
    /// The constant keeps its name; only the words changed, and nothing stores them.
    public static let contextNeedsRetry = "Couldn't find the source words near this Margin"
    public static let transcriptionNeedsRetry = "Transcription needs retry"

    /// The error the transcription clients throw while the listener has not been asked yet (#4715): the app holds iOS's
    /// prompt until its own card has asked. A Margin that meets it is waiting, not failed.
    public static let speechRecognitionNotYetAskedError = "speech_recognition_not_yet_asked"

    /// What a waiting Margin's status line says.
    public static let transcriptNotYetAsked = "No transcript yet."

    public static func isSpeechRecognitionOff(error: String) -> Bool {
        error.contains(speechRecognitionOffError)
    }

    public static func isSpeechRecognitionNotYetAsked(error: String) -> Bool {
        error.contains(speechRecognitionNotYetAskedError)
    }

    /// The banner after transcribing a saved voice Margin fails, or nil when the Margin is only waiting for the
    /// listener's answer (no banner, so J11 doesn't read "transcript failed" for it). `isRetry` is a retry of a
    /// Margin that may already have words, which it keeps.
    public static func notice(error: String, isRetry: Bool) -> Notice? {
        if isSpeechRecognitionNotYetAsked(error: error) { return nil }
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
    /// the same reason, and the context words alone would hide how to fix both.
    public static func marginAttention(
        transcriptionStatus: String,
        speechRecognitionOff: Bool,
        speechRecognitionNotYetAsked: Bool = false,
        contextUnavailable: Bool,
        recordingMissing: Bool
    ) -> String {
        let transcript = marginStatus(
            transcriptionStatus: transcriptionStatus, speechRecognitionOff: speechRecognitionOff,
            speechRecognitionNotYetAsked: speechRecognitionNotYetAsked)
        if transcriptionStatus == "failed", speechRecognitionOff || speechRecognitionNotYetAsked, let transcript { return transcript }
        if contextUnavailable { return contextNeedsRetry }
        if recordingMissing { return "Recording is unavailable" }
        return transcript ?? "Margin needs attention"
    }

    /// The Margin's own status line for a transcript that isn't ready, or nil when it is.
    /// `speechRecognitionOff` is the permission now: a Margin whose transcript failed can
    /// only be transcribed once it's back on.
    /// `speechRecognitionNotYetAsked` is true for a failed Margin that waits on the listener's answer to the app's card (#4715).
    public static func marginStatus(
        transcriptionStatus: String, speechRecognitionOff: Bool, speechRecognitionNotYetAsked: Bool = false
    ) -> String? {
        switch transcriptionStatus {
        case "failed":
            if speechRecognitionOff { return "No transcript: Speech Recognition is off. Turn it on in Settings." }
            return speechRecognitionNotYetAsked ? transcriptNotYetAsked : transcriptionNeedsRetry
        case "pending":
            // Only live work is "pending": a launch settles the orphans as "failed" (#942).
            return "Transcribing…"
        default:
            return nil
        }
    }
}
