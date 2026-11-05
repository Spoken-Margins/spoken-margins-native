import SessionKit
import SwiftUI

/// Dictating a spoken note (#3108, #1609 slice 1): Record starts a take, Stop ends it, and each take shows its
/// transcript as it arrives. The phone can lock while a take runs. Tap-to-play on a sentence is the next step.
struct SpokenNoteRecordingView: View {
    @EnvironmentObject private var app: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = SpokenNoteRecorderModel()

    private var takes: [SpokenNoteTake] { recorder.snapshot?.note.takes ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    if let message = recorder.message {
                        FailureMessageLabel(message)
                            .accessibilityIdentifier("spokenNote.message")
                    }
                    ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                        takeCard(number: index + 1, take: take)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppColors.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .navigationTitle("Spoken Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            await recorder.finish()
                            dismiss()
                        }
                    }
                    .disabled(recorder.isBusy)
                    .accessibilityIdentifier("spokenNote.done")
                }
            }
        }
        // A take that is running ends only with Stop or Done, never by a swipe.
        .interactiveDismissDisabled(recorder.phase != .idle || !takes.isEmpty)
        .task { recorder.attach(app.makeSpokenNoteRecorderEnvironment()) }
        // Anything other than Done that removes this screen still closes a take that is running, so it is saved.
        .onDisappear {
            let recorder = recorder
            Task { @MainActor in await recorder.finish() }
        }
        .accessibilityIdentifier("spokenNote.screen")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch recorder.phase {
            case .recording:
                Label("Recording", systemImage: "waveform")
                    .font(.title2.weight(.bold))
                Text(Self.clock(recorder.elapsed))
                    .font(.system(.largeTitle, design: .rounded).monospacedDigit())
                    .accessibilityLabel("Recorded \(Int(recorder.elapsed)) seconds")
                Text("You can lock your phone. It keeps recording.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            case .starting:
                Label("Starting", systemImage: "mic")
                    .font(.title2.weight(.bold))
            case .stopping:
                Label("Saving", systemImage: "tray.and.arrow.down")
                    .font(.title2.weight(.bold))
            case .idle:
                Text(takes.isEmpty ? "Say what's on your mind." : "Record another take to add to this note.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColors.text)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spokenNote.status")
    }

    private func takeCard(number: Int, take: SpokenNoteTake) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Take \(number) · \(Self.clock(TimeInterval(take.durationMs) / 1_000))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
            if take.hasTranscript {
                Text(take.sentences.map(\.text).joined(separator: " "))
                    .foregroundStyle(AppColors.text)
            } else if recorder.snapshot?.transcribingTakeIds.contains(take.id) == true {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Writing this down…").foregroundStyle(AppColors.secondaryText)
                }
            } else if recorder.snapshot?.failedTranscriptTakeIds.contains(take.id) == true {
                Text("Couldn't write this take down. The audio is saved. It may have been silent, or speech recognition may be off.")
                    .foregroundStyle(AppColors.secondaryText)
                Button("Try again") { recorder.retryTranscript(forTake: take.id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("spokenNote.retry.\(take.id)")
            } else {
                Text("No words heard.").foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppColors.border) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spokenNote.take.\(take.id)")
    }

    private var controls: some View {
        Button {
            if recorder.phase == .recording { recorder.stop() } else { recorder.record() }
        } label: {
            Label(
                recorder.phase == .recording ? "Stop" : (takes.isEmpty ? "Record" : "Record another take"),
                systemImage: recorder.phase == .recording ? "stop.fill" : "mic.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(recorder.isBusy)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(AppColors.bone)
        .accessibilityIdentifier("spokenNote.record")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
