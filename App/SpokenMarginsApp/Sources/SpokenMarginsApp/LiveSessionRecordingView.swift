import Combine
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
    /// The small label above the anchor card; a live session's is "Live session".
    var anchorCaption = "Live session"
    /// False for a recording that has no session to write into (`QuickMarginRecordingView`, #4927).
    var offersWriteInstead = true

    var state: MarginRecordingScreenState {
        let subtitle = anchorSubtitle()
        return MarginRecordingScreenState(
            phase: capture.isStarting ? .starting : .recording,
            isFinishing: false,
            hasKeepableAudio: capture.isRecording(for: sessionId),
            startedAt: capture.recordingStartedAt ?? Date(),
            anchorCaption: anchorCaption,
            anchorIsLocked: false,
            anchorTitle: anchorTitle,
            anchorSubtitle: subtitle,
            anchorSpokenDetail: subtitle,
            justHeard: nil,
            reply: nil,
            error: nil,
            canRetry: false,
            offersWriteInstead: offersWriteInstead
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

/// The recording screen for "Record a Margin" when nothing runs (#4927): no live session and nothing in the player. It
/// is the live session's recording screen, driven by the same capture, with the Margin going to a quick session when
/// Finish is tapped (`LiveSessionSpokenCapture.quickDestination`). It closes when the recording ends, however it ends,
/// and says why when the microphone could not start. There is no writing screen to fall back to here, so Write instead
/// is not offered.
struct QuickMarginRecordingView: View {
    @ObservedObject private var capture = LiveSessionSpokenCapture.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var links = LiveSessionLinkRouter.shared
    /// The line for a recording that could not start (the microphone is off, or a call holds it).
    @State private var notice: String?

    static let caption = "Nothing is playing"
    static let title = "Quick session"
    static let subtitle = "Kept in your Library when you finish"

    var body: some View {
        LiveSessionRecordingView(
            capture: capture, sessionId: LiveSessionSpokenCapture.quickDestination, anchorTitle: Self.title,
            anchorSubtitle: { Self.subtitle }, onWriteInstead: { _ in dismiss() }, onCancelled: { dismiss() },
            anchorCaption: Self.caption, offersWriteInstead: false
        )
        // Taken on the next turn, as the live session screen does, so clearing it is not overwritten by the set that sent it.
        .onReceive(capture.$notice.compactMap { $0 }.receive(on: DispatchQueue.main)) { line in
            notice = line
            capture.notice = nil
        }
        .onAppear { links.quickScreenAppeared() }
        .onDisappear { links.quickScreenDisappeared() }
        // A recording that has ended closes the screen, unless there is a line to read first (one here, or one waiting
        // to be taken): that is answered, then the screen closes.
        .onChange(of: capture.isRecordingQuick, initial: true) { _, recording in
            if !recording && notice == nil && capture.notice == nil { dismiss() }
        }
        .alert("Record a Margin", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            // Never closes the screen over a recording that is still going: it would have no Finish or Cancel.
            Button("OK", role: .cancel) { if !capture.isRecordingQuick { dismiss() } }
        } message: {
            Text(notice ?? "")
        }
    }
}
