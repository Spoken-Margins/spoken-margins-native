import SessionKit

extension Gate1AppModel {
    /// Shows what came of an interruption's resume request in diagnostics, and logs it in the
    /// timestamped playback events beside the interruption itself (#538).
    func noteSpeechInterruptionResume(_ outcome: SpeechInterruptionResume) {
        diagnostics["speechPlaybackInterruption"] = outcome.diagnostic
        recordDeveloperDiagnostic(outcome.kind, outcome.fields)
    }
}
