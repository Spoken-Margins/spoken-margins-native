import SessionKit
import SwiftUI

struct ExperienceRecordingView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.feedbackDeliveryEffects) private var feedbackEffects
    @State private var isDiscardConfirmationPresented = false
    /// #1669: Write instead on a recording that holds something worth keeping asks first.
    @State private var isWriteInsteadConfirmationPresented = false
    /// Ignores a stray second tap of a double tap on Add a Margin (#148).
    @State private var saveTapGuard = RecordingSaveTapGuard(appearedAt: Date())

    private var isPreparing: Bool {
        model.isRequestingRecordingPermission && !model.snapshot.isRecording
    }

    /// #937: whether audio is really arriving. Before the recording starts there is nothing to judge.
    private var captureHealth: MarginCaptureSupervisor.Health {
        model.snapshot.isRecording ? model.recordingCaptureHealth : .capturing
    }

    private var isStartingCapture: Bool { captureHealth == .starting }

    private var isNotCapturing: Bool {
        if case .notCapturing = captureHealth { return true }
        return false
    }

    /// #783: the line before iOS's first microphone prompt is on screen, waiting for Continue.
    private var showsMicrophonePrimer: Bool {
        isPreparing && model.microphonePrimer.isShowing
    }

    var body: some View {
        ZStack {
            AppColors.listeningBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    replyCaption
                    recordingTime
                    if !showsMicrophonePrimer { anchor }
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
        .onDisappear(perform: model.listeningScreenAppeared) // the screen behind it is drawn now (#148)
        .alert("Discard this recording?", isPresented: $isDiscardConfirmationPresented) {
            Button("Keep recording", role: .cancel) {}
            Button("Discard recording", role: .destructive, action: model.cancelInterjection)
        } message: {
            Text("This Margin has not been saved. Discarding returns to the locked listening position.")
        }
        .accessibilityAction(.escape) {
            guard !model.isFinishingInterjection else { return }
            if model.snapshot.isRecording {
                isDiscardConfirmationPresented = true
            } else {
                model.cancelInterjection()
            }
        }
    }

    /// The shared Margin this recording answers (#473).
    @ViewBuilder
    private var replyCaption: some View {
        ExperienceReplyChoiceRow(
            choice: model.pendingMarginReplyChoice, captionColor: .white, identifierPrefix: "recording",
            switchReply: model.toggleReplyOfCurrentMargin
        )
    }

    /// The words and the icon carry the state together, never colour alone (#937).
    private var statusTitle: String {
        if model.isFinishingInterjection { return "Saving Margin…" }
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
            Text(model.recordingHasKeepableAudio
                ? "The microphone stopped. What you said so far is kept if you tap Save."
                : "Nothing is being recorded right now.")
                .font(.title3)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recording.notCapturing.label")
        } else {
            TimelineView(.periodic(from: context.startedAt, by: 1)) { timeline in
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
            Label(isPreparing ? "Current listening position" : "Saved listening position", systemImage: isPreparing ? "headphones" : "lock.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppColors.listeningBackground)
            Text(context.itemTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.listeningBackground)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(context.locationTitle) · \(context.progressPercent)%")
                .font(.subheadline)
                .foregroundStyle(AppColors.listeningBackground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.captureBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording anchor. \(context.itemTitle), \(context.locationTitle), \(context.progressPercent) percent")
        .accessibilityIdentifier("recording.anchor")
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = model.lastError {
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
            Label(model.isFinishingInterjection ? "Saving Margin…" : "Save & resume", systemImage: "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RecordingSaveButtonStyle())
        .disabled(isPreparing || isStartingCapture || model.isFinishingInterjection)
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
        .disabled(model.isFinishingInterjection)
        .accessibilityIdentifier("recording.cancel.button")
    }

    private var actionDock: some View {
        VStack(spacing: 8) {
            if showsMicrophonePrimer {
                Button {
                    // The second tap of a double tap on Add a Margin must not skip the line (#148).
                    guard saveTapGuard.accepts(tapAt: Date()) else { return }
                    model.continueMicrophonePrimer()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.captureBackground)
                .foregroundStyle(AppColors.listeningBackground)
                .accessibilityIdentifier("recording.microphonePrimer.continue")
            }
            if isNotCapturing, model.canRetryMicrophone {
                Button(action: model.retryMicrophone) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.captureBackground)
                .foregroundStyle(AppColors.listeningBackground)
                .disabled(model.isFinishingInterjection)
                .accessibilityIdentifier("recording.retryMicrophone.button")
            }
            if isPreparing || model.snapshot.isRecording {
                Button("Write instead", systemImage: "square.and.pencil", action: writeInstead)
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .disabled(model.isFinishingInterjection)
                    .accessibilityIdentifier("recording.writeInstead.button")
                    // Attached to the button, so on iPad the dialog points at it.
                    .confirmationDialog("Write this Margin instead?", isPresented: $isWriteInsteadConfirmationPresented, titleVisibility: .visible) {
                        Button("Discard recording and write", role: .destructive, action: model.switchRecordingToWrittenMargin)
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

    private var context: RecordingPresentationContext {
        model.recordingPresentationContext ?? RecordingPresentationContext(
            snapshot: model.snapshot,
            startedAt: Date()
        )
    }

    private func requestFinish() {
        guard saveTapGuard.accepts(tapAt: Date()) else { return }
        model.requestFinishInterjection()
    }

    /// Before the recording starts nothing is lost. Once it holds sound, the listener confirms the discard, as for Cancel.
    private func writeInstead() {
        guard !model.isFinishingInterjection else { return }
        if isPreparing {
            model.switchPendingVoiceCaptureToWrittenMargin()
        } else if model.recordingHasKeepableAudio {
            isWriteInsteadConfirmationPresented = true
        } else {
            model.switchRecordingToWrittenMargin()
        }
    }

    private func requestDiscard() {
        guard !model.isFinishingInterjection else { return }
        if model.snapshot.isRecording {
            isDiscardConfirmationPresented = true
        } else {
            model.cancelInterjection()
        }
    }

    private func elapsedDescription(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(context.startedAt)))
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
