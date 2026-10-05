import SessionKit

extension Gate1AppModel {
    /// Shows what came of an interruption's resume request in diagnostics, and logs it in the
    /// timestamped playback events beside the interruption itself (#538).
    func noteSpeechInterruptionResume(_ outcome: SpeechInterruptionResume) {
        diagnostics["speechPlaybackInterruption"] = outcome.diagnostic
        recordDeveloperDiagnostic(outcome.kind, outcome.fields)
    }

    /// Logs the resume once `resumePlayback()` returned without throwing. A starting snapshot is
    /// held until playback plays or fails, so a resume that never makes sound isn't logged as one.
    func noteSpeechInterruptionResumeReturned() {
        guard let outcome = speechInterruptionResumeWatch.resumeReturned(snapshot) else {
            diagnostics["speechPlaybackInterruption"] = "resume_starting"
            return
        }
        noteSpeechInterruptionResume(outcome)
    }

    /// Called on every snapshot change; logs a held resume once it settles.
    func settleSpeechInterruptionResume() {
        guard let outcome = speechInterruptionResumeWatch.snapshotChanged(snapshot) else { return }
        noteSpeechInterruptionResume(outcome)
    }
}
