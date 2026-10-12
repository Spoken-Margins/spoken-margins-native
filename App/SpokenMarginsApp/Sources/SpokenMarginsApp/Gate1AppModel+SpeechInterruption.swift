import Foundation
import SessionKit
import SessionKitAudio

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

    func handleMediaPlaybackInterruption(_ event: AudioPlaybackInterruptionEvent) {
        switch event {
        case .began:
            guard snapshot.status.isPlaybackActive, let engine else {
                diagnostics["mediaPlaybackInterruption"] = "pause_skipped"
                return
            }
            do {
                snapshot = try engine.reconcileSystemInitiatedPause()
                refreshSelectedItem()
                diagnostics["mediaPlaybackInterruption"] = "paused"
            } catch {
                diagnostics["mediaPlaybackInterruption"] = "pause_failed:\(error.localizedDescription)"
                reportWarning("Playback could not be paused cleanly after the audio route changed.")
            }
        case .endedShouldResume:
            guard snapshot.status == .paused, let engine else {
                diagnostics["mediaPlaybackInterruption"] = "resume_skipped"
                return
            }
            do {
                snapshot = try engine.resumePlayback()
                refreshSelectedItem()
                diagnostics["mediaPlaybackInterruption"] = "resumed"
            } catch {
                diagnostics["mediaPlaybackInterruption"] = "resume_failed:\(error.localizedDescription)"
                reportWarning("Playback paused after the interruption. Tap Play to resume.")
            }
        }
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
                refreshSelectedItem()
                diagnostics["speechPlaybackInterruption"] = "paused"
            } catch {
                diagnostics["speechPlaybackInterruption"] = "pause_failed:\(error.localizedDescription)"
                reportWarning("Playback could not be paused cleanly after the audio route changed.")
            }
        case .endedShouldResume:
            guard snapshot.status == .paused, let engine else {
                noteSpeechInterruptionResume(.skipped)
                return
            }
            do {
                snapshot = try engine.resumePlayback()
                refreshSelectedItem()
                noteSpeechInterruptionResumeReturned()
            } catch {
                noteSpeechInterruptionResume(.failed(reason: error.localizedDescription))
                reportWarning("Playback paused after the interruption. Tap Play to resume.")
            }
        }
    }
}
