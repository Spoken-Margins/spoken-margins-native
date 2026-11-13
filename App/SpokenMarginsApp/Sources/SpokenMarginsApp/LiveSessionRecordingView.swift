import SessionKit
import SwiftUI

/// The recording screen for a spoken Margin in a live session: the same screen playback shows, driven by the phone's
/// `LiveSessionSpokenCapture` instead of the app model (#3491). There is no reply caption or just-heard line, and
/// no microphone primer or retry, because the live recorder asks for the microphone before the screen opens.
struct LiveSessionRecordingView: View {
    @ObservedObject var capture: LiveSessionSpokenCapture
    let sessionId: String
    let anchorTitle: String
    let anchorSubtitle: () -> String
    /// Called after the recording has been thrown away, when the listener chose to write instead. It is given the
    /// moment the recording began: the written Margin belongs to the place the listener was when they tapped Add a
    /// Margin, not to the moment they changed their mind.
    let onWriteInstead: (Date?) -> Void
    /// Given the photo that was waiting for this recording when the listener chose to write instead (#2708), just before
    /// `onWriteInstead`, so the written Margin keeps the picture. Not called when there was no photo.
    var onKeepPhoto: (LiveSessionPhotoStore.Staged) -> Void = { _ in }
    /// The kind of session, which words the hint under a photo.
    var kind: ElsewhereKind = .meeting
    /// Called after the recording was thrown away (Cancel, confirmed), so the screen that owns the cover closes it.
    var onCancelled: () -> Void = {}

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
            // A photo waiting for this recording goes with it: Cancel means "I don't want this" (#2708).
            cancel: {
                capture.cancel(sessionId: sessionId)
                onCancelled()
            },
            writeInstead: { _ in
                // A Margin taken with a photo is placed where the listener tapped Photo; cancel clears both.
                let began = capture.photoPlacedAt ?? capture.recordingStartedAt
                // The picture is kept: the written Margin takes it.
                if let photo = capture.cancel(sessionId: sessionId, keepingPhoto: true) { onKeepPhoto(photo) }
                onWriteInstead(began)
            },
            continuePrimer: {},
            retry: {},
            toggleReply: {},
            disappeared: {}
        )
    }

    var body: some View {
        MarginRecordingScreen(state: state, actions: actions, lead: lead)
    }

    /// The photo just taken, above the recorder, with the line that helps the listener say where it is from.
    private var lead: AnyView? {
        guard let photo = capture.photo else { return nil }
        return AnyView(LiveSessionPhotoLead(url: photo.url, hint: LiveSessionPhotoMargin.hint(for: kind)).foregroundStyle(.white))
    }
}
