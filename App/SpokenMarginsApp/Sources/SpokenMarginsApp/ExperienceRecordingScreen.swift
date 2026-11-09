import SessionKit
import SwiftUI

/// Playback's recording screen: reads the app model and hands the shared screen plain values and closures (#3491).
struct ExperienceRecordingView: View {
    @EnvironmentObject private var model: Gate1AppModel

    private var isPreparing: Bool {
        model.isRequestingRecordingPermission && !model.snapshot.isRecording
    }

    /// #937: whether audio is really arriving. Before the recording starts there is nothing to judge.
    private var captureHealth: MarginCaptureSupervisor.Health {
        model.snapshot.isRecording ? model.recordingCaptureHealth : .capturing
    }

    private var phase: MarginRecordingScreenState.Phase {
        if isPreparing { return model.microphonePrimer.isShowing ? .primer : .preparing }
        switch captureHealth {
        case .starting: return .starting
        case .notCapturing: return .notCapturing
        case .capturing: return .recording
        }
    }

    private var context: RecordingPresentationContext {
        model.recordingPresentationContext ?? RecordingPresentationContext(
            snapshot: model.snapshot,
            startedAt: Date()
        )
    }

    private var state: MarginRecordingScreenState {
        let context = context
        return MarginRecordingScreenState(
            phase: phase,
            isFinishing: model.isFinishingInterjection,
            hasKeepableAudio: model.recordingHasKeepableAudio,
            startedAt: context.startedAt,
            anchorCaption: isPreparing ? "Current listening position" : "Saved listening position",
            anchorIsLocked: !isPreparing,
            anchorTitle: context.itemTitle,
            anchorSubtitle: "\(context.locationTitle) · \(context.progressPercent)%",
            anchorSpokenDetail: "\(context.locationTitle), \(context.progressPercent) percent",
            justHeard: model.justHeardCue,
            reply: model.pendingMarginReplyChoice,
            error: model.lastError,
            canRetry: model.canRetryMicrophone
        )
    }

    private var actions: MarginRecordingScreenActions {
        MarginRecordingScreenActions(
            finish: model.requestFinishInterjection,
            cancel: model.cancelInterjection,
            writeInstead: { _ in
                // Before the recording starts nothing is lost; afterwards the screen has already asked.
                if isPreparing {
                    model.switchPendingVoiceCaptureToWrittenMargin()
                } else {
                    model.switchRecordingToWrittenMargin()
                }
            },
            continuePrimer: model.continueMicrophonePrimer,
            retry: model.retryMicrophone,
            toggleReply: model.toggleReplyOfCurrentMargin,
            disappeared: model.listeningScreenAppeared
        )
    }

    var body: some View {
        MarginRecordingScreen(state: state, actions: actions)
    }
}
