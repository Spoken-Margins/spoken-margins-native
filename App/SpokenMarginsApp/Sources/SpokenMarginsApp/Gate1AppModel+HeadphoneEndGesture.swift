import Foundation
import SessionKit

/// Connects `HeadphoneEndGestureMonitor` to the model (#3650). The decisions are `HeadphoneMuteGestureDetector`'s
/// and `RecordingTransportGuard`'s; this only supplies the clock, the setting and the "end the Margin" action.
extension Gate1AppModel {
    /// The one monitor, kept on the capture watcher.
    var headphoneEndGestureMonitor: HeadphoneEndGestureMonitor {
        if let monitor = captureWatcher.headphoneMonitor { return monitor }
        let monitor = makeHeadphoneEndGestureMonitor()
        captureWatcher.headphoneMonitor = monitor
        return monitor
    }

    private func makeHeadphoneEndGestureMonitor() -> HeadphoneEndGestureMonitor {
        HeadphoneEndGestureMonitor(
            log: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) },
            recordingMs: { [weak self] in self?.captureWatcher.elapsedMs ?? 0 },
            sinceRouteChangeMs: { [weak self] in self?.captureWatcher.msSinceRouteChange },
            endMargin: { [weak self] in self?.endMarginFromHeadphoneMute() },
            captureLevel: { [weak self] in
                // The level now and the audio captured so far: a press that muted the uplink shows as the level
                // falling to silence while the speaker keeps talking (#3650).
                guard let reading = self?.captureWatcher.currentReading() else { return [:] }
                var fields = ["capturedMs": String(reading.capturedMs), "recorderRunning": String(reading.recorderRunning)]
                if let peak = reading.peakPowerDb, peak.isFinite { fields["peakNowDb"] = String(Int(peak.rounded())) }
                if let input = reading.inputRoute { fields["recorderInput"] = input }
                return fields
            }
        )
    }

    /// A real mute change while a Margin records: the headset's press as iOS reports it. The same finish as a Now
    /// Playing command (`transport.ends_margin`), so the save path is unchanged.
    private func endMarginFromHeadphoneMute() {
        guard snapshot.isRecording, !isFinishingInterjection else { return }
        recordDeveloperDiagnostic("transport.ends_margin", [
            "command": "mute_state", "origin": "headphone_mute",
            "recordingMs": String(captureWatcher.elapsedMs),
            "sinceRouteChangeMs": captureWatcher.msSinceRouteChange.map(String.init) ?? "none",
            "appState": Gate2AppState.isInBackground() ? "background" : "foreground",
        ])
        performGate2CompactCommand(.finishInterjection, origin: "headphone_mute")
    }

    /// Hands the monitor the name of every remote command Now Playing receives (the live-speech controller's and the
    /// stream player's), so the log shows what iOS delivered during a recording.
    func noteRemoteCommandArrival(_ name: String) {
        headphoneEndGestureMonitor.noteRemoteCommand(name)
    }

    func noteRemoteCommandAnswer(_ name: String, answer: String) {
        headphoneEndGestureMonitor.noteRemoteCommandAnswer(name, answer: answer)
    }
}
