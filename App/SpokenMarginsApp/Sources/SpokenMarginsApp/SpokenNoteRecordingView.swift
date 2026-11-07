import SessionKit
import SwiftUI

/// Dictating a spoken note (#3108, #1609 slice 1): Record starts a take, Stop ends it, and each take shows its
/// transcript as it arrives. The phone can lock while a take runs. Tapping a sentence plays the audio behind it.
/// A note opened from the Library shows its takes at once and can take more.
struct SpokenNoteRecordingView: View {
    var opening: SpokenNoteOpening?

    @EnvironmentObject private var app: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = SpokenNoteRecorderModel()
    @StateObject private var player = SpokenNotePlayerModel()
    /// Export: the note's audio and transcript, through the share sheet (#3660).
    @StateObject private var noteExport = SpokenNoteExportModel()

    private var takes: [SpokenNoteTake] { recorder.snapshot?.note.takes ?? [] }
    private var hasTranscript: Bool { takes.contains { $0.hasTranscript } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    if let message = recorder.message ?? player.message {
                        FailureMessageLabel(message)
                            .accessibilityIdentifier("spokenNote.message")
                    }
                    ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                        takeCard(number: index + 1, takeIndex: index, take: take)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppColors.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .miniPlayerKeepOut()
            .navigationTitle("Spoken Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        guard let note = recorder.snapshot?.note, let folder = recorder.noteFolder else { return }
                        noteExport.export(note: note, noteFolder: folder, title: opening?.title ?? SpokenNoteItem.defaultTitle)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    // Nothing to export before the first take, and no export while a take is being made or saved.
                    .disabled(takes.isEmpty || recorder.phase != .idle || noteExport.isPreparing)
                    .accessibilityHint("Shares this note's audio and words")
                    .accessibilityIdentifier("spokenNote.export")
                }
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
        .task { recorder.attach(app.makeSpokenNoteRecorderEnvironment(), opening: opening) }
        // Anything other than Done that removes this screen still closes a take that is running, so it is saved.
        .onDisappear {
            player.stop()
            let recorder = recorder
            Task { @MainActor in await recorder.finish() }
        }
        .spokenNoteExportSheet($noteExport.files)
        .alert("Couldn't export", isPresented: Binding(get: { noteExport.message != nil }, set: { if !$0 { noteExport.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(noteExport.message ?? "")
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
                    .accessibilityAddTraits(.isHeader)
                if hasTranscript {
                    Text("Tap a sentence to hear what you said.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spokenNote.status")
    }

    private func takeCard(number: Int, takeIndex: Int, take: SpokenNoteTake) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Take \(number) · \(Self.clock(TimeInterval(take.durationMs) / 1_000))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
            if take.hasTranscript {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(take.sentences.enumerated()), id: \.offset) { sentenceIndex, sentence in
                        sentenceRow(SpokenNote.SentenceRef(takeIndex: takeIndex, sentenceIndex: sentenceIndex), sentence)
                    }
                }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spokenNote.take.\(take.id)")
    }

    /// One sentence, as a button: tap to hear the audio behind it, tap again to stop. The sentence that is sounding
    /// shows a stop symbol and a tinted background, so it never rests on color alone. Nothing plays while recording.
    private func sentenceRow(_ ref: SpokenNote.SentenceRef, _ sentence: SpokenNoteSentence) -> some View {
        let note = recorder.snapshot?.note
        let isPlaying = player.playing == ref
        let hasAudio = note?.playback(for: ref) != nil
        return Button {
            guard let note, let folder = recorder.noteFolder else { return }
            player.toggle(ref, in: note, folder: folder) { recorder.pauseOtherPlayback() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(hasAudio ? AppColors.evergreen : AppColors.secondaryText)
                    .accessibilityHidden(true)
                Text(sentence.text)
                    .foregroundStyle(AppColors.text)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPlaying ? AppColors.softGreen : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasAudio || recorder.phase != .idle)
        .accessibilityLabel(sentence.text)
        .accessibilityHint(isPlaying ? "Stops playing" : "Plays the audio for this sentence")
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
        .accessibilityIdentifier("spokenNote.sentence.\(ref.takeIndex).\(ref.sentenceIndex)")
    }

    private var controls: some View {
        Button {
            if recorder.phase == .recording {
                recorder.stop()
            } else {
                // A sentence that is playing, or starting, hands the audio session back before recording takes it. The
                // screen is busy from this tap on, so a second tap or a sentence tap can't slip in meanwhile.
                recorder.record { await player.stopAndWait() }
            }
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
