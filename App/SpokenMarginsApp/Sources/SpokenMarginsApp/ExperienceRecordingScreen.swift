import SwiftUI

struct ExperienceRecordingView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var isDiscardConfirmationPresented = false

    private var isPreparing: Bool {
        model.isRequestingRecordingPermission && !model.snapshot.isRecording
    }

    var body: some View {
        ZStack {
            AppColors.listeningBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    recordingTime
                    anchor
                    feedback
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { finishControl.padding(24) }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionDock }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.screen")
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

    private var status: some View {
        Label(
            model.isFinishingInterjection ? "Saving Margin…" : (isPreparing ? "Preparing microphone" : "Recording Margin"),
            systemImage: isPreparing ? "mic.badge.plus" : "record.circle.fill"
        )
        .font(.headline)
        .foregroundStyle(AppColors.listeningAccent)
    }

    @ViewBuilder
    private var recordingTime: some View {
        if isPreparing {
            HStack(spacing: 12) {
                ProgressView().tint(AppColors.listeningAccent)
                Text("Waiting for microphone access")
                    .font(.body)
                    .foregroundStyle(.white)
            }
        } else {
            TimelineView(.periodic(from: context.startedAt, by: 1)) { timeline in
                Text(elapsedDescription(at: timeline.date))
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Recording duration \(elapsedDescription(at: timeline.date))")
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

    private var finishControl: some View {
        Button(action: model.requestFinishInterjection) {
            Label(model.isFinishingInterjection ? "Saving Margin…" : "Save & resume", systemImage: "checkmark")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppColors.captureBackground)
        .foregroundStyle(AppColors.listeningBackground)
        .disabled(isPreparing || model.isFinishingInterjection)
        .accessibilityIdentifier("recording.finish.button")
    }

    private var actionDock: some View {
        VStack(spacing: 8) {
            if isPreparing {
                Button("Write instead", systemImage: "square.and.pencil", action: model.switchPendingVoiceCaptureToWrittenMargin)
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("recording.writeInstead.button")
            }
            Button(role: .destructive, action: requestDiscard) {
                Label("Cancel", systemImage: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
            .disabled(model.isFinishingInterjection)
            .accessibilityIdentifier("recording.cancel.button")
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
            itemTitle: model.selectedItem.title.isEmpty ? "Current item" : model.selectedItem.title,
            locationTitle: model.snapshot.chapterTitle ?? "Current listening position",
            progressPercent: model.snapshot.currentPlaybackProgressPercent,
            startedAt: Date()
        )
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
