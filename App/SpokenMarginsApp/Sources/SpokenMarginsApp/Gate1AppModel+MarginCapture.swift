import Foundation
import SessionKit

/// Whether a spoken Margin is really being recorded, and what happens when it is not (#937).
///
/// `MarginCaptureWatcher` polls the recorder and `MarginCaptureSupervisor` decides. This extension
/// connects them to the model: the recording screen reads `recordingCaptureHealth` and says
/// "Recording" only while audio is arriving.
extension Gate1AppModel {
    func startCaptureWatch() {
        recordingCaptureHealth = .starting
        captureWatcher.start(
            reading: { [weak self] in self?.engine?.recordingCaptureReading() },
            restart: { [weak self] in try self?.engine?.restartRecordingCapture() },
            changed: { [weak self] health, restarts in self?.captureHealthChanged(health, restarts: restarts) }
        )
    }

    func endCaptureWatch() {
        captureWatcher.stop()
        recordingCaptureHealth = .capturing
    }

    private func captureHealthChanged(_ health: MarginCaptureSupervisor.Health, restarts: Int) {
        let wasCapturing = recordingCaptureHealth == .capturing
        recordingCaptureHealth = health
        var fields = engine?.recordingCaptureDiagnostics() ?? [:]
        fields["health"] = health.diagnosticName
        fields["restarts"] = String(restarts)
        recordDeveloperDiagnostic("margin.capture.health", fields)
        diagnostics["lastVoiceCapture"] = Self.captureSummary(fields)
        switch health {
        case .capturing where !wasCapturing:
            reportSuccess("Recording Margin.")
        case .notCapturing:
            reportFailure(captureWatcher.hasKeepableAudio
                ? "The microphone stopped partway. What you said before is kept if you tap Save."
                : "The microphone isn't recording, so nothing is being saved. Tap Try again, or cancel and write the Margin instead.")
        default:
            break
        }
    }

    /// The listener tapped Try again on a recording screen that says the microphone isn't recording.
    func retryMicrophone() {
        guard snapshot.isRecording, canRetryMicrophone else { return }
        lastError = nil
        captureWatcher.retry()
    }

    /// Try again restarts the recorder and deletes what it holds, so it is not offered once the
    /// recording holds audio worth saving.
    var canRetryMicrophone: Bool { snapshot.isRecording && captureWatcher.canRetry }

    /// The recording stopped partway but holds speech: Save keeps it.
    var recordingHasKeepableAudio: Bool { snapshot.isRecording && captureWatcher.hasKeepableAudio }

    /// What saving the recording would keep. An empty recording is discarded here, not saved: nil means it was.
    func verdictForSavingRecording() -> MarginCaptureSupervisor.SaveVerdict? {
        let verdict = captureWatcher.saveVerdict()
        recordFinalCaptureDiagnostics(verdict.rawValue)
        guard verdict == .discardEmpty else { return verdict }
        discardEmptyRecording()
        return nil
    }

    /// Finish from the Lock Screen, a Live Activity or a widget goes around `finishInterjection()`, so it
    /// asks here first. Nil means the recording was empty and is gone: Finish must not save it. Cancel from
    /// there is logged. Every other command passes.
    func verdictForCompactCommand(_ command: CompactControlCommand) -> MarginCaptureSupervisor.SaveVerdict? {
        if command == .cancelInterjection { recordFinalCaptureDiagnostics("cancelled") }
        guard command == .finishInterjection, snapshot.isRecording else { return .save }
        return verdictForSavingRecording()
    }

    /// One line at the end of every recording, written while the recorder can still be asked: the audio it
    /// really took in against the time on the clock, the restarts, the route and category, and what happened
    /// to the Margin. `lastVoiceCapture` becomes this line, so a Margin that failed names its cause (#937).
    func recordFinalCaptureDiagnostics(_ outcome: String) {
        guard snapshot.isRecording, !captureWatcher.finalRecorded else { return }
        captureWatcher.finalRecorded = true
        var fields = engine?.recordingCaptureDiagnostics() ?? [:]
        fields["health"] = (captureWatcher.health ?? .capturing).diagnosticName
        fields["restarts"] = String(captureWatcher.restarts)
        fields["watchedCapturedMs"] = String(captureWatcher.capturedMs)
        fields["wallMs"] = String(captureWatcher.elapsedMs)
        fields["outcome"] = outcome
        recordDeveloperDiagnostic("margin.capture.final", fields)
        diagnostics["lastVoiceCapture"] = Self.captureSummary(fields)
    }

    private static func captureSummary(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    /// Save was tapped on a recording that took in no audio: say so, and don't keep an empty voice as a Margin.
    private func discardEmptyRecording() {
        cancelInterjection()
        reportFailure("Nothing was recorded, so no Margin was saved. The microphone didn't pick up any sound. Try again, or write the Margin instead.")
    }

    /// The line after a spoken Margin is saved. A recording the microphone cut short says so.
    func reportMarginSaved(_ verdict: MarginCaptureSupervisor.SaveVerdict) {
        if verdict == .saveCutShort {
            reportWarning("Margin saved, but part of it may be missing. The microphone stopped early.")
        } else {
            reportConfirmation("Margin saved. Transcription is continuing in the background.")
        }
    }
}
