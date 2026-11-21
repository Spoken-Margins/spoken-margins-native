import Foundation
import SessionKit
import SessionKitAudio

extension Gate1AppModel {
    /// Tries a podcast or publisher recording's resume again when iOS refuses to reactivate the session (#2183).
    /// One per process: a stored property can't live in an extension, and Gate1AppModel is capped (hot-file ratchet).
    static let mediaInterruptionResumeRetrier = InterruptionResumeRetrier()

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

    func handleMediaPlaybackInterruption(_ event: AudioPlaybackInterruptionEvent) {
        switch event {
        case .began:
            Self.mediaInterruptionResumeRetrier.cancel()
            guard snapshot.status.isPlaybackActive, let engine else {
                diagnostics["mediaPlaybackInterruption"] = "pause_skipped"
                return
            }
            do {
                snapshot = try engine.reconcileSystemInitiatedPause()
                refreshSelectedItemInBackground()
                diagnostics["mediaPlaybackInterruption"] = "paused"
            } catch {
                diagnostics["mediaPlaybackInterruption"] = "pause_failed:\(SafeErrorText.describe(error))"
                reportWarning("Playback could not be paused cleanly after the audio route changed.")
            }
        case .endedResumeRequested:
            guard snapshot.status == .paused, let engine else {
                diagnostics["mediaPlaybackInterruption"] = "resume_skipped"
                return
            }
            // A written Margin is open: Save or Cancel plays the item, so this is neither a failure nor a retry (#4831).
            if engine.deferResumeToWrittenCapture() {
                diagnostics["mediaPlaybackInterruption"] = "resume_deferred_to_written_margin"
                return
            }
            do {
                snapshot = try engine.resumePlaybackAfterInterruption()
                refreshSelectedItemInBackground()
                diagnostics["mediaPlaybackInterruption"] = "resumed"
            } catch {
                diagnostics["mediaPlaybackInterruption"] = "resume_failed:\(InterruptionResumeRetrier.describe(error))"
                retryMediaResumeAfterInterruption(after: error, engine: engine)
            }
        }
    }

    /// iOS can refuse to reactivate the session for a moment after another app lets go of it, most often in the
    /// background or in Low Power Mode. Tries again a few times while the item is still paused where it was, then
    /// leaves it paused and says why (#2183).
    private func retryMediaResumeAfterInterruption(after error: Error, engine: SessionEngine) {
        let sessionId = snapshot.sessionId
        let targetId = snapshot.targetId
        // Where it paused. A seek, skip, or a Play and Pause by the listener moves this, and then the item is theirs.
        let pausedAtMs = snapshot.currentMediaTimeMs
        Self.mediaInterruptionResumeRetrier.begin(
            after: error,
            stillWaiting: { [weak self] in
                guard let self else { return false }
                return snapshot.status == .paused && snapshot.sessionId == sessionId && snapshot.targetId == targetId
                    && snapshot.currentMediaTimeMs == pausedAtMs && !snapshot.isRecording
            },
            // A written Margin opened while the retries ran: Save or Cancel plays the item, so the retries stop (#4846).
            handOver: { [weak self] in
                guard let self, snapshot.status == .paused, snapshot.sessionId == sessionId, snapshot.targetId == targetId,
                      !snapshot.isRecording else { return false }
                return engine.deferResumeToWrittenCapture()
            },
            attempt: { [weak self] in
                guard let self else { return }
                snapshot = try engine.resumePlaybackAfterInterruption()
                refreshSelectedItemInBackground()
            },
            report: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .resumed(let attempt):
                    diagnostics["mediaPlaybackInterruption"] = "resumed_on_retry_\(attempt)"
                case .retryFailed(let attempt, let reason):
                    diagnostics["mediaPlaybackInterruption"] = "resume_retry_\(attempt)_failed:\(reason)"
                case .gaveUp(let attempts, let reason):
                    diagnostics["mediaPlaybackInterruption"] = "resume_gave_up_after_\(attempts)_retries:\(reason)"
                    reportWarning("Playback paused after the interruption. Tap Play to resume.")
                case .abandoned(let attempts):
                    diagnostics["mediaPlaybackInterruption"] = "resume_retry_abandoned_after_\(attempts)"
                case .deferred(let attempts):
                    diagnostics["mediaPlaybackInterruption"] = "resume_deferred_to_written_margin_after_\(attempts)_retries"
                }
                recordDeveloperDiagnostic("media.interruption_resume", ["outcome": diagnostics["mediaPlaybackInterruption"] ?? "none"])
            }
        )
    }

    func handleSpeechPlaybackInterruption(_ event: AudioPlaybackInterruptionEvent) {
        switch event {
        case .began:
            // Counted so a device report can show whether chunk-boundary pauses (#183) come
            // from audio interruptions.
            diagnostics["speechPlaybackInterruptionCount"] = "\(Int(diagnostics["speechPlaybackInterruptionCount"] ?? "0").map { $0 + 1 } ?? 1)"
            guard snapshot.status.isPlaybackActive, let engine else {
                diagnostics["speechPlaybackInterruption"] = "pause_skipped"
                return
            }
            do {
                snapshot = try engine.reconcileSystemInitiatedPause()
                refreshSelectedItemInBackground()
                diagnostics["speechPlaybackInterruption"] = "paused"
            } catch {
                diagnostics["speechPlaybackInterruption"] = "pause_failed:\(SafeErrorText.describe(error))"
                reportWarning("Playback could not be paused cleanly after the audio route changed.")
            }
        case .endedResumeRequested:
            guard snapshot.status == .paused, let engine else {
                noteSpeechInterruptionResume(.skipped)
                return
            }
            // A written Margin is open: Save or Cancel plays the item, so this is neither a failure nor a warning (#4831).
            if engine.deferResumeToWrittenCapture() {
                diagnostics["speechPlaybackInterruption"] = "resume_deferred_to_written_margin"
                return
            }
            do {
                snapshot = try engine.resumePlayback()
                refreshSelectedItemInBackground()
                noteSpeechInterruptionResumeReturned()
            } catch {
                noteSpeechInterruptionResume(.failed(reason: SafeErrorText.describe(error)))
                reportWarning("Playback paused after the interruption. Tap Play to resume.")
            }
        }
    }
}
