#if SM_LOCKED_MARGIN_SPIKE
import ActivityKit
import AVFoundation
import Foundation
import SessionKit
import UIKit

/// Spike #3086: the Lock Screen record button runs here, in the app process, inside the intent's own run. It goes
/// through the same compact-control path as every other Lock Screen command, then records what iOS allowed.
extension Gate1AppModel {
    static let lockedMarginIntentOrigin = "locked_margin_intent"

    func installLockedMarginIntentBridge() {
        Gate2RecordMarginIntentBridge.handler = { [weak self] finish in
            guard let self else { throw Gate2RecordMarginIntentError.appUnavailable }
            try await runLockedMarginIntent(finish: finish)
        }
    }

    func runLockedMarginIntent(finish: Bool) async throws {
        let action: LockedMarginIntentReport.Action = finish ? .finish : .begin
        let appState = Self.lockedMarginAppStateName(UIApplication.shared.applicationState)
        let protectedData = UIApplication.shared.isProtectedDataAvailable
        let liveActivitiesBefore = Self.activeLiveActivityCount()
        let audioCategory = AVAudioSession.sharedInstance().category.rawValue
        let wasRecording = snapshot.isRecording
        let failureBefore = diagnostics["recentFailure"]
        recordDeveloperDiagnostic("margin.locked_intent.received", [
            "action": action.rawValue, "appState": appState,
            "protectedData": protectedData ? "available" : "unavailable_maybe_locked",
            "liveActivities": String(liveActivitiesBefore), "audioCategory": audioCategory
        ])
        // A begin while recording, or a finish with nothing recording, only reports.
        if finish == wasRecording {
            dispatchGate2CompactCommand(finish ? .finishInterjection : .beginInterjection, origin: Self.lockedMarginIntentOrigin)
            // Production starts the recorder one main-actor turn after the request, so wait for it to land.
            let deadline = Date().addingTimeInterval(3)
            while snapshot.isRecording == wasRecording, diagnostics["recentFailure"] == failureBefore, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let failureAfter = diagnostics["recentFailure"]
        let report = LockedMarginIntentReport(
            action: action,
            appState: appState,
            protectedDataAvailable: protectedData,
            liveActivitiesBefore: liveActivitiesBefore,
            liveActivitiesAfter: Self.activeLiveActivityCount(),
            audioCategoryBefore: audioCategory,
            microphonePermission: microphoneAccess.status().map { String(describing: $0) } ?? "unknown",
            wasRecording: wasRecording,
            isRecording: snapshot.isRecording,
            failure: failureAfter != failureBefore ? failureAfter : nil
        )
        recordDeveloperDiagnostic("margin.locked_intent", report.fields)
        diagnostics["lastLockedMarginIntent"] = report.summary
        if !report.succeeded { throw LockedMarginIntentFailure(report: report) }
    }

    private static func activeLiveActivityCount() -> Int {
        Activity<Gate2LiveActivityAttributes>.activities.filter { $0.activityState == .active }.count
    }

    private static func lockedMarginAppStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

struct LockedMarginIntentFailure: LocalizedError {
    let report: LockedMarginIntentReport

    var errorDescription: String? {
        "The Margin did not \(report.action == .begin ? "start" : "finish") (\(report.outcome.rawValue))."
    }
}
#endif
