import Foundation
import SessionKit

/// Connects `HeadphoneEndGestureMonitor` to the model (#3650). The decisions are `HeadphoneMuteGestureDetector`'s
/// and `RecordingTransportGuard`'s; this only supplies the clock, the setting and the "end the Margin" action.
extension Gate1AppModel {
    func makeHeadphoneEndGestureMonitor() -> HeadphoneEndGestureMonitor {
        HeadphoneEndGestureMonitor(
            log: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) },
            recordingMs: { [weak self] in self?.captureWatcher.elapsedMs ?? 0 },
            sinceRouteChangeMs: { [weak self] in self?.captureWatcher.msSinceRouteChange },
            endsMarginOnMutePair: {
                // The same setting that lets a double press start a Margin lets it end one.
                HeadphoneDoublePressAction(
                    storedValue: UserDefaults.standard.string(forKey: HeadphoneDoublePressAction.storageKey)
                ) == .addMargin
            },
            endMargin: { [weak self] in self?.endMarginFromHeadphoneMutePair() }
        )
    }

    /// Two real mute changes within 0.6 s while a Margin records: the headset's double press as iOS reports it.
    /// The same finish as a Now Playing command (`transport.ends_margin`), so the save path is unchanged.
    private func endMarginFromHeadphoneMutePair() {
        guard snapshot.isRecording, !isFinishingInterjection else { return }
        recordDeveloperDiagnostic("transport.ends_margin", [
            "command": "mute_pair", "origin": "headphone_mute_pair",
            "recordingMs": String(captureWatcher.elapsedMs),
            "sinceRouteChangeMs": captureWatcher.msSinceRouteChange.map(String.init) ?? "none",
            "appState": Gate2AppState.isInBackground() ? "background" : "foreground",
        ])
        performGate2CompactCommand(.finishInterjection, origin: "headphone_mute_pair")
    }

    /// Hands the monitor the name of every remote command Now Playing receives (the live-speech controller's and the
    /// stream player's), so the log shows what iOS delivered during a recording.
    func noteRemoteCommandArrival(_ name: String) {
        headphoneEndGestureMonitor.noteRemoteCommand(name)
    }
}
