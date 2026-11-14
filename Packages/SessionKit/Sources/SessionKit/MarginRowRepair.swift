import Foundation

/// The fix a Margins row offers beside its status (#3856): a Retry button for "Context needs retry" or "Transcription
/// needs retry", the same retry the Margin's detail offers, one tap from the row. A row shows the fix for its own fault
/// (the batch rule with #4018, #4019, #4020, #4183, #4176 and #3863).
///
/// The rule starts from the status text `TranscriptionFailureWording.marginAttention` picks for the row, so it inherits that
/// order and the button can only appear beside the words it fixes: Speech Recognition off, or a missing recording, shows
/// its own text and no button. The rule is stricter than the detail view on purpose: while the Margin's own transcription is
/// pending, a context retry would refuse, so the row offers nothing.
public enum MarginRowRepair: Equatable, Sendable {
    case none
    case retryContext
    case retryTranscription

    /// - Parameters:
    ///   - contextStatus: the Margin's source-context status, nil when it has none.
    ///   - canRetryTranscription: a voice Margin whose transcript isn't ready and whose recording is kept.
    ///   - contextRetryRunning, transcriptionRetryRunning: a retry for this Margin is already running, so a second tap would
    ///     only start another.
    public static func of(
        isWritten: Bool,
        speechRecognitionOff: Bool,
        transcriptionStatus: String,
        contextStatus: AnchorContextStatus?,
        recordingMissing: Bool,
        canRetryTranscription: Bool,
        contextRetryRunning: Bool,
        transcriptionRetryRunning: Bool
    ) -> MarginRowRepair {
        // A written Margin has no transcript or recording to repair, and its row never shows a status.
        guard !isWritten else { return .none }
        let status = TranscriptionFailureWording.marginAttention(
            transcriptionStatus: transcriptionStatus,
            speechRecognitionOff: speechRecognitionOff,
            contextUnavailable: contextStatus == .unavailable,
            recordingMissing: recordingMissing)
        switch status {
        case TranscriptionFailureWording.contextNeedsRetry:
            return transcriptionStatus != "pending" && !contextRetryRunning ? .retryContext : .none
        case TranscriptionFailureWording.transcriptionNeedsRetry:
            return canRetryTranscription && !transcriptionRetryRunning ? .retryTranscription : .none
        default:
            return .none
        }
    }
}

/// What the banner says once a source-context retry has finished (#3856). It reads the status the retry stored, never the
/// fact that it finished, so a retry that found no words doesn't announce a recovery.
public enum ContextRetryResultWording {
    /// - Parameter status: the Margin's context status after the retry, nil when its row isn't listed.
    public static func message(status: AnchorContextStatus?) -> String {
        switch status {
        case .ready: "Source context recovered."
        case .unavailable: "No words were found near this Margin."
        case .pending, .none: "Context retry finished."
        }
    }
}
