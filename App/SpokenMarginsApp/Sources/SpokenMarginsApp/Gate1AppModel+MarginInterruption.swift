import Foundation
import SessionKit

/// A call, Siri or lost headphones stopping a spoken Margin (#771).
extension Gate1AppModel {
    /// Has the recorder report interruptions here. The policy lives with the recorder, so a rebuilt
    /// engine starts with no resume pending.
    func reportingMarginInterruptions(_ recorder: RecordingClient) -> RecordingClient {
        let holder = MarginInterruptionPolicyHolder()
        (recorder as? RecordingInterruptionReporting)?.onInterruption = { [weak self] event, seconds in
            Task { @MainActor [weak self] in self?.handleMarginRecordingInterruption(event, recordedSeconds: seconds, holder: holder) }
        }
        return recorder
    }

    /// What was said is kept (or a stray start dropped) without resuming the source. The policy
    /// resumes it when a call ends, if the source is still where the Margin left it.
    func handleMarginRecordingInterruption(
        _ event: MarginRecordingInterruptionEvent, recordedSeconds: TimeInterval?, holder: MarginInterruptionPolicyHolder
    ) {
        let seconds = snapshot.isRecording ? (recordedSeconds ?? 0) : nil
        let action = holder.policy.handle(event, recordedSeconds: seconds, pausedSource: .paused(in: snapshot))
        let cause = event == .routeLost ? "headphones_disconnected" : "call_or_siri"
        recordDeveloperDiagnostic("margin.interruption", [
            "event": "\(event)", "action": "\(action)", "recordedSeconds": seconds.map { String(format: "%.1f", $0) } ?? "none",
        ])
        switch action {
        case .none:
            return
        case .resumeSource:
            run { engine in snapshot = try engine.resumePlayback() }
            streamingSpeechQueue.resumeAfterInterjection()
            return
        case .saveCutShort:
            run { engine in
                snapshot = try engine.finishInterjection(audioRef: nil, resumesSource: false)
                refreshSelectedItem()
                recordSavedInterjectionForOnboarding()
                let interjection = latestInterjectionNeedingTranscription()
                if let interjection { scheduleTranscription(for: interjection) }
                diagnostics["lastMarginCutShort"] = "\(interjection?.id ?? "unknown") \(cause) \(String(format: "%.1f", seconds ?? 0))s"
                reportWarning(event == .routeLost
                    ? "Margin saved. It stopped when your headphones disconnected. Tap Play to continue."
                    : "Margin saved. A call or Siri cut it short.")
            }
        case .discard:
            run { engine in
                snapshot = try engine.cancelInterjection(resumesSource: false)
                refreshSelectedItem()
                reportWarning("The Margin was interrupted before you said anything, so it wasn't kept.")
            }
        }
        // A call's end resumes only the session and place this save or discard left.
        holder.policy.sourceSettled(at: .paused(in: snapshot))
        if !snapshot.isRecording {
            recordingPresentationContext = nil
            refreshMarginRows()
        }
    }
}

@MainActor
final class MarginInterruptionPolicyHolder {
    var policy = MarginRecordingInterruptionPolicy()
}
