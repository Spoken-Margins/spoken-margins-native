import SwiftUI

/// The recording screen for a spoken Margin in a live session: the same screen playback shows, driven by the phone's
/// `LiveSessionSpokenCapture` instead of the app model (#3491). There is no reply caption or just-heard line, and
/// no microphone primer or retry, because the live recorder asks for the microphone before the screen opens.
struct LiveSessionRecordingView: View {
    @ObservedObject var capture: LiveSessionSpokenCapture
    let sessionId: String
    let anchorTitle: String
    let anchorSubtitle: () -> String
    /// Called after the recording has been thrown away, when the listener chose to write instead.
    let onWriteInstead: () -> Void

    var state: MarginRecordingScreenState {
        let subtitle = anchorSubtitle()
        return MarginRecordingScreenState(
            phase: capture.isStarting ? .starting : .recording,
            isFinishing: false,
            hasKeepableAudio: capture.isRecording(for: sessionId),
            startedAt: capture.recordingStartedAt ?? Date(),
            anchorCaption: "Live session",
            anchorIsLocked: false,
            anchorTitle: anchorTitle,
            anchorSubtitle: subtitle,
            anchorSpokenDetail: subtitle,
            justHeard: nil,
            reply: nil,
            error: nil,
            canRetry: false
        )
    }

    var actions: MarginRecordingScreenActions {
        MarginRecordingScreenActions(
            finish: { capture.stopAndFile() },
            cancel: { capture.cancel(sessionId: sessionId) },
            writeInstead: { _ in
                capture.cancel(sessionId: sessionId)
                onWriteInstead()
            },
            continuePrimer: {},
            retry: {},
            toggleReply: {},
            disappeared: {}
        )
    }

    var body: some View {
        MarginRecordingScreen(state: state, actions: actions)
    }
}
