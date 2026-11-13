import SessionKit
import SwiftUI

/// What the recording screen shows, as plain values. Playback's recording and a live session's recording both build
/// one, so the two present the same screen and neither knows about the other's model (#3491).
struct MarginRecordingScreenState: Equatable {
    enum Phase: Equatable {
        /// Waiting for microphone access.
        case preparing
        /// The line before iOS's first microphone prompt is on screen, waiting for Continue (#783).
        case primer
        /// The recorder accepted the start and has not yet reported audio.
        case starting
        /// No audio is arriving, or the recorder stopped.
        case notCapturing
        case recording
    }

    var phase: Phase
    /// Saving after Save & resume was tapped. Shown over whichever phase the recording was in.
    var isFinishing = false
    /// What was recorded so far is kept if the listener taps Save.
    var hasKeepableAudio = false
    var startedAt: Date
    /// The small label above the anchor card, like "Saved listening position".
    var anchorCaption: String
    /// Locked shows a lock; otherwise a headphones icon.
    var anchorIsLocked: Bool
    var anchorTitle: String
    var anchorSubtitle: String
    /// What VoiceOver adds after the title, like "Chapter 3, 40 percent".
    var anchorSpokenDetail: String
    var justHeard: String?
    var reply: MarginReplyChoice?
    var error: String?
    var canRetry = false

    var isPreparing: Bool { phase == .preparing || phase == .primer }
    var showsMicrophonePrimer: Bool { phase == .primer }
    var isStarting: Bool { phase == .starting }
    var isNotCapturing: Bool { phase == .notCapturing }
    /// Anything past preparing: the recorder has been started, so a discard has something to lose.
    var isRecording: Bool { !isPreparing }
}

/// What the recording screen's buttons do. The screen owns the confirmations (discard, write instead); an action runs
/// after the listener has confirmed.
struct MarginRecordingScreenActions {
    var finish: () -> Void
    /// Cancel, after the listener confirmed a discard when there was a recording to lose.
    var cancel: () -> Void
    /// Write instead; `confirmedDiscard` is true when the listener confirmed throwing away a recording that held sound.
    var writeInstead: (_ confirmedDiscard: Bool) -> Void
    var continuePrimer: () -> Void
    var retry: () -> Void
    var toggleReply: () -> Void
    var disappeared: () -> Void
}

struct MarginRecordingScreen: View {
    let state: MarginRecordingScreenState
    let actions: MarginRecordingScreenActions
    /// What only one caller has, shown under the status line: a live session's photo and its hint (#2708).
    var lead: AnyView?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.feedbackDeliveryEffects) private var feedbackEffects
    @State private var isDiscardConfirmationPresented = false
    /// #1669: Write instead on a recording that holds something worth keeping asks first.
    @State private var isWriteInsteadConfirmationPresented = false
    /// Ignores a stray second tap of a double tap on Add a Margin (#148).
    @State private var saveTapGuard = RecordingSaveTapGuard(appearedAt: Date())

    private var isPreparing: Bool { state.isPreparing }
    private var isStartingCapture: Bool { state.isStarting }
    private var isNotCapturing: Bool { state.isNotCapturing }
    private var showsMicrophonePrimer: Bool { state.showsMicrophonePrimer }

    var body: some View {
        ZStack {
            AppColors.listeningBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    if let lead, !showsMicrophonePrimer { lead }
                    replyCaption
                    recordingTime
                    if !showsMicrophonePrimer { anchor }
                    if !showsMicrophonePrimer { justHeard }
                    feedback
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionDock }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.screen")
        .announcesScreenChange()
        // The screen opens on "Preparing microphone"; a listener who can't see it needs to hear when the microphone is live.
        .onChange(of: statusTitle) { _, title in feedbackEffects.announce(title) }
        .onAppear { saveTapGuard = RecordingSaveTapGuard(appearedAt: Date()) }
        .onDisappear(perform: actions.disappeared) // the screen behind it is drawn now (#148)
        .alert("Discard this recording?", isPresented: $isDiscardConfirmationPresented) {
            Button("Keep recording", role: .cancel) {}
            Button("Discard recording", role: .destructive, action: actions.cancel)
        } message: {
            Text("This Margin has not been saved. Discarding returns to the locked listening position.")
        }
        .accessibilityAction(.escape) {
            requestDiscard()
        }
    }

    /// The shared Margin this recording answers (#473).
    @ViewBuilder
    private var replyCaption: some View {
        if let reply = state.reply {
            ExperienceReplyChoiceRow(
                choice: reply, captionColor: .white, identifierPrefix: "recording",
                switchReply: actions.toggleReply
            )
        }
    }

    /// The words and the icon carry the state together, never colour alone (#937).
    private var statusTitle: String {
        if state.isFinishing { return "Saving Margin…" }
        if isPreparing { return "Preparing microphone" }
        if isStartingCapture { return "Starting microphone" }
        if isNotCapturing { return "Microphone isn't recording" }
        return "Recording Margin"
    }

    private var statusIcon: String {
        if isPreparing || isStartingCapture { return "mic.badge.plus" }
        if isNotCapturing { return "exclamationmark.triangle.fill" }
        return "record.circle.fill"
    }

    private var status: some View {
        Label(statusTitle, systemImage: statusIcon)
            .font(.headline)
            .foregroundStyle(AppColors.listeningAccent)
            .accessibilityIdentifier("recording.status.label")
    }

    @ViewBuilder
    private var recordingTime: some View {
        if showsMicrophonePrimer {
            Text(MicrophonePrimer.message)
                .font(.title3)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recording.microphonePrimer.text")
        } else if isPreparing {
            HStack(spacing: 12) {
                ProgressView().tint(AppColors.listeningAccent)
                Text("Waiting for microphone access")
                    .font(.body)
                    .foregroundStyle(.white)
            }
        } else if isStartingCapture {
            HStack(spacing: 12) {
                ProgressView().tint(AppColors.listeningAccent)
                Text("Waiting for sound from the microphone")
                    .font(.body)
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("recording.starting.label")
        } else if isNotCapturing {
            Text(state.hasKeepableAudio
                ? "The microphone stopped. What you said so far is kept if you tap Save."
                : "Nothing is being recorded right now.")
                .font(.title3)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recording.notCapturing.label")
        } else {
            TimelineView(.periodic(from: state.startedAt, by: 1)) { timeline in
                Text(elapsedDescription(at: timeline.date))
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Recording duration \(elapsedDescription(at: timeline.date))")
                    .accessibilityIdentifier("recording.duration.label")
            }
        }
    }

    private var anchor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.anchorCaption, systemImage: state.anchorIsLocked ? "lock.fill" : "headphones")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppColors.listeningBackground)
            Text(state.anchorTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.listeningBackground)
                .fixedSize(horizontal: false, vertical: true)
            Text(state.anchorSubtitle)
                .font(.subheadline)
                .foregroundStyle(AppColors.listeningBackground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.captureBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording anchor. \(state.anchorTitle), \(state.anchorSpokenDetail)")
        .accessibilityIdentifier("recording.anchor")
    }

    /// What was said just before recording began, so the listener can pick up the thought (#1491).
    @ViewBuilder
    private var justHeard: some View {
        if let cue = state.justHeard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Just heard", systemImage: "quote.opening")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppColors.listeningAccent)
                Text(cue)
                    .font(.body)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Just heard. \(cue)")
            .accessibilityIdentifier("recording.justHeard")
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = state.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(AppColors.captureBackground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Save & resume takes the bottom-row spot Add a Margin has on the playback screen, so starting and
    /// stopping a Margin happens under the same thumb (#148). The guard window in `requestFinish` keeps a stray
    /// second tap of a double tap on Add a Margin from saving an empty Margin.
    private var finishControl: some View {
        Button(action: requestFinish) {
            Label(state.isFinishing ? "Saving Margin…" : "Save & resume", systemImage: "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RecordingSaveButtonStyle())
        .disabled(isPreparing || isStartingCapture || state.isFinishing)
        .accessibilityHidden(showsMicrophonePrimer)
        // VoiceOver meets Save before the destructive Cancel, as when Save was at the top.
        .accessibilitySortPriority(1)
        .accessibilityIdentifier("recording.finish.button")
    }

    /// Cancel is rare, so it is the small button on the far left of the bottom row.
    private var cancelControl: some View {
        Button(role: .destructive, action: requestDiscard) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "xmark").accessibilityLabel("Cancel")
                } else {
                    Label("Cancel", systemImage: "xmark")
                }
            }
            .font(.subheadline)
            .frame(minWidth: 44, minHeight: 52)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
        .disabled(state.isFinishing)
        .accessibilityIdentifier("recording.cancel.button")
    }

    private var actionDock: some View {
        VStack(spacing: 8) {
            if showsMicrophonePrimer {
                Button {
                    // The second tap of a double tap on Add a Margin must not skip the line (#148).
                    guard saveTapGuard.accepts(tapAt: Date()) else { return }
                    actions.continuePrimer()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.captureBackground)
                .foregroundStyle(AppColors.listeningBackground)
                .accessibilityIdentifier("recording.microphonePrimer.continue")
            }
            if isNotCapturing, state.canRetry {
                Button(action: actions.retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.captureBackground)
                .foregroundStyle(AppColors.listeningBackground)
                .disabled(state.isFinishing)
                .accessibilityIdentifier("recording.retryMicrophone.button")
            }
            if isPreparing || state.isRecording {
                Button(action: writeInstead) {
                    Label("Write instead", systemImage: "square.and.pencil").frame(minHeight: 44).contentShape(Rectangle())
                }
                    .foregroundStyle(.white)
                    .disabled(state.isFinishing)
                    .accessibilityIdentifier("recording.writeInstead.button")
                    // Attached to the button, so on iPad the dialog points at it.
                    .confirmationDialog("Write this Margin instead?", isPresented: $isWriteInsteadConfirmationPresented, titleVisibility: .visible) {
                        Button("Discard recording and write", role: .destructive) { actions.writeInstead(true) }
                        Button("Keep recording", role: .cancel) {}
                    } message: {
                        Text("The recording has not been saved. Writing starts at the same listening position, without it.")
                    }
            }
            HStack(spacing: 12) {
                cancelControl
                finishControl
            }
            .accessibilityElement(children: .contain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(AppColors.listeningBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
        }
    }

    private func requestFinish() {
        guard saveTapGuard.accepts(tapAt: Date()) else { return }
        actions.finish()
    }

    /// Before the recording starts nothing is lost. Once it holds sound, the listener confirms the discard, as for Cancel.
    private func writeInstead() {
        guard !state.isFinishing else { return }
        if isPreparing {
            actions.writeInstead(false)
        } else if state.hasKeepableAudio {
            isWriteInsteadConfirmationPresented = true
        } else {
            actions.writeInstead(false)
        }
    }

    private func requestDiscard() {
        guard !state.isFinishing else { return }
        if state.isRecording {
            isDiscardConfirmationPresented = true
        } else {
            actions.cancel()
        }
    }

    private func elapsedDescription(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(state.startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Save & resume looks like Add a Margin and dims the moment it is touched, so one tap clearly registers (#148).
private struct RecordingSaveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(minHeight: 52)
            .foregroundStyle(AppColors.interjectText)
            .background(AppColors.captureBackground.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
