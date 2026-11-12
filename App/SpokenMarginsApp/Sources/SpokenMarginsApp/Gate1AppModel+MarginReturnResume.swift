import Foundation
import SessionKit

extension Gate1AppModel {
    /// One per process: a stored property can't live in an extension, and Gate1AppModel is capped (hot-file ratchet).
    static let marginReturnResume = MarginReturnResume()

    /// Asks the engine to resume the source. `afterMargin` is true when a Margin's voice just ended and the source is
    /// the Margin's to bring back: with the screen locked iOS can refuse the audio session for a moment, so that
    /// return tries once more, and when it still fails the listener gets a Resume button, not an error banner
    /// they can't act on (#4110). Every failed resume writes a `resume.failed` playback event with the error's type
    /// and domain/code, so a device export says why.
    func resumeSource(afterMargin: Bool) {
        let resume = { [weak self] (engine: SessionEngine) throws in
            guard let self else { return }
            snapshot = try hangTelemetry.labels.scoped(Self.engineRunLabel(caller: "resumePlayback")) { try engine.resumePlayback() }
            refreshSelectedItemInBackground() // like pause(): the icon flips without waiting for the item reload (#2098)
            reportSuccess("Resumed.")
        }
        guard afterMargin, let engine else {
            Self.marginReturnResume.cancel()
            run { engine in
                do { try resume(engine) } catch {
                    recordDeveloperDiagnostic(MarginReturnResume.failedKind, MarginReturnResume.failureFields(
                        error, appIsInBackground: Gate2AppState.isInBackground(), willRetry: false))
                    throw error // `run` reports it as before
                }
            }
            return
        }
        let sessionId = snapshot.sessionId
        let targetId = snapshot.targetId
        // Where it paused. A seek, skip, or a Play and Pause by the listener moves this, and then the source is theirs.
        // A text or PDF source has no media time, so its place is the text offset and progress.
        let pausedAtMs = snapshot.currentMediaTimeMs
        let pausedAtText = snapshot.currentTextStart
        let pausedAtPercent = snapshot.progressPercent
        Self.marginReturnResume.resume(
            appIsInBackground: Gate2AppState.isInBackground(),
            stillWaiting: { [weak self] in
                guard let self else { return false }
                return snapshot.status == .paused && snapshot.sessionId == sessionId && snapshot.targetId == targetId
                    && snapshot.currentMediaTimeMs == pausedAtMs && snapshot.currentTextStart == pausedAtText
                    && snapshot.progressPercent == pausedAtPercent && !snapshot.isRecording
                    // Another Margin took the voice, or its card is up and the offer paused the source.
                    && playingImportedCommentary == nil && playingInterjectionAudioId == nil
                    && pendingImportedCommentary == nil && marginMomentConductor?.isPlayingVoice != true
                    && !marginVoiceIsHeldForRecording
            },
            attempt: { try resume(engine) },
            record: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) },
            finished: { [weak self] outcome in self?.marginReturnResumeFinished(outcome) }
        )
    }

    private func marginReturnResumeFinished(_ outcome: MarginReturnResume.Outcome) {
        switch outcome {
        case .resumed:
            diagnostics["marginReturnResume"] = "resumed"
        case .resumedOnRetry:
            diagnostics["marginReturnResume"] = "resumed_on_retry"
        case .abandoned:
            diagnostics["marginReturnResume"] = "retry_abandoned"
        case .needsListener(let reason, let retried):
            diagnostics["marginReturnResume"] = "needs_listener:\(retried ? "retried:" : "")\(reason)"
            // An error, not a warning: a warning goes after 6 s, and the listener who locked the phone finds it later.
            // An error stays until they act on it or close it. The Lock Screen play control reaches the same call.
            let message = "Playback paused after the Margin."
            statusMessage = "Error"
            lastError = message
            presentFeedback(UserFeedbackEvent(
                kind: .error, message: message,
                action: UserFeedbackEvent.Action(
                    title: "Resume", accessibilityLabel: "Resume playback", identifier: "resumeAfterMargin",
                    perform: { [weak self] in self?.resumePlayback() }
                )
            ))
            diagnostics["recentFailure"] = "Margin return could not resume: \(reason)" // the type and code, never the text
        }
    }
}
