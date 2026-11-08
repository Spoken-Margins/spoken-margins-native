import SessionKit
import SwiftUI

/// Dictating a spoken note (#3108, #1609 slice 1): Record starts a take, Stop ends it, and each take shows its
/// transcript as it arrives. The phone can lock while a take runs. Play plays the whole note start to finish through the
/// app's own playback (Now, the Lock Screen, headphones), lighting the sentence that is sounding (#3662). Tapping a
/// sentence jumps there while the note plays, and otherwise plays just that sentence.
/// A note opened from the Library shows its takes at once and can take more. Its title is at the top of the screen once it has
/// a take: tap it to rename the note (#3663).
struct SpokenNoteRecordingView: View {
    var opening: SpokenNoteOpening?

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = SpokenNoteRecorderModel()
    @StateObject private var player = SpokenNotePlayerModel()
    /// Play for the whole note (#3662): gets it ready, then the shared playback plays it.
    @StateObject private var wholePlay = SpokenNoteWholePlayModel()
    @State private var playbackTick = 0 // bumped by each progress tick: the sounding sentence follows the playhead
    /// Export: the note's audio and transcript, through the share sheet (#3660).
    @StateObject private var noteExport = SpokenNoteExportModel()
    /// The rename prompt, while the listener is typing a new title (#3663).
    @State private var renaming: SpokenNoteRenameTarget?

    private var takes: [SpokenNoteTake] { recorder.snapshot?.note.takes ?? [] }
    private var hasTranscript: Bool { takes.contains { $0.hasTranscript } }
    /// This note is the item the app's playback has open, playing or paused.
    private var isThisNoteOpen: Bool {
        guard let note = recorder.snapshot?.note else { return false }
        return model.hasActiveSession && model.snapshot.itemId == SpokenNoteItem.itemId(forNoteId: note.id)
            && model.snapshot.phase != .finished
    }
    private var isThisNotePlaying: Bool { isThisNoteOpen && model.snapshot.status.isPlaybackActive }
    /// The sentence being heard now, while the whole note is open in playback and its place in the joined audio is known.
    private var soundingSentence: SpokenNote.SentenceRef? {
        guard isThisNoteOpen, let timeline = wholePlay.timeline else { return nil }
        return timeline.ref(atMs: model.playbackClock.position.mediaTimeMs ?? 0)
    }

    private var exportWouldLeaveATakeOut: Bool {
        guard let snapshot = recorder.snapshot else { return false }
        return snapshot.hasUnsavedTake || !snapshot.transcribingTakeIds.isEmpty
    }

    var body: some View {
        let _ = playbackTick
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleHeader
                    status
                    if let message = recorder.message ?? player.message ?? wholePlay.message {
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
                        noteExport.export(note: note, noteFolder: folder, title: recorder.title ?? opening?.title ?? SpokenNoteItem.defaultTitle)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    // Nothing to export before the first take, none while a take is being made or saved, and none while a take
                    // is not yet in the note or its words are still being written down: those would leave it out.
                    .disabled(takes.isEmpty || recorder.phase != .idle || noteExport.isPreparing || exportWouldLeaveATakeOut)
                    .accessibilityHint("Exports this note's audio and words, to save or send")
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
        .task { recorder.attach(model.makeSpokenNoteRecorderEnvironment(), opening: opening) }
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
        .onChange(of: recorder.snapshot?.note) { _, _ in refreshWholeTimeline() }
        .onChange(of: recorder.noteFolder) { _, _ in refreshWholeTimeline() }
        // Anything other than Done that removes this screen still closes a take that is running, so it is saved.
        .onDisappear {
            player.stop()
            wholePlay.abandon()
            noteExport.abandon()
            let recorder = recorder
            Task { @MainActor in await recorder.finish() }
        }
        .spokenNoteExportFlow(noteExport)
        .spokenNoteRenameAlert($renaming) { recorder.titleChanged(to: $0) }
        .accessibilityIdentifier("spokenNote.screen")
    }

    /// The note's name, with a pencil to say it can be changed: one tap opens the rename prompt. Shown once the note has a
    /// take, which is when it has a Library row to rename.
    @ViewBuilder private var titleHeader: some View {
        if let note = recorder.snapshot?.note, !takes.isEmpty, let title = recorder.title {
            Button {
                renaming = SpokenNoteRenameTarget(itemId: SpokenNoteItem.itemId(forNoteId: note.id), currentTitle: title)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.evergreen)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.isBusy)
            .accessibilityLabel(title)
            .accessibilityHint("Renames this note")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("spokenNote.title")
        }
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
        let isSounding = soundingSentence == ref
        let isPlaying = player.playing == ref || isSounding
        let hasAudio = note?.playback(for: ref) != nil
        // While the whole note is open in playback, a sentence is a place to jump to.
        let jumpStartMs = isThisNoteOpen ? wholePlay.timeline?.startMs(of: ref) : nil
        return Button {
            if let jumpStartMs {
                // A sentence that is playing hands the audio session back before the note moves and plays on.
                Task {
                    await player.stopAndWait()
                    // Record may have been tapped while the audio session was handed back: never play over a take.
                    guard recorder.phase == .idle else { return }
                    let labels = MainThreadOperationLabels.shared // so a slow jump names its step (#2256)
                    labels.scoped("spokenNote.jump") {
                        model.seekMedia(toMediaTimeMs: jumpStartMs)
                        if !model.snapshot.status.isPlaybackActive { model.resumePlayback() }
                    }
                }
                return
            }
            guard let note, let folder = recorder.noteFolder else { return }
            player.toggle(ref, in: note, folder: folder) { recorder.pauseOtherPlayback() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSounding ? "speaker.wave.2.fill" : (isPlaying ? "stop.fill" : "play.fill"))
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
        .accessibilityHint(jumpStartMs != nil ? "Plays the note from this sentence" : (isPlaying ? "Stops playing" : "Plays the audio for this sentence"))
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
        .accessibilityIdentifier("spokenNote.sentence.\(ref.takeIndex).\(ref.sentenceIndex)")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if !takes.isEmpty { playNoteButton }
            recordButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(AppColors.bone)
    }

    /// Plays the whole note, takes in order, through the app's own playback; the same control pauses and resumes it.
    private var playNoteButton: some View {
        Button {
            guard let note = recorder.snapshot?.note else { return }
            // A sentence that is playing hands the audio session back before the note takes it.
            wholePlay.play(noteId: note.id, app: model, beforeStart: { await player.stopAndWait() }, shouldStart: { recorder.phase == .idle })
        } label: {
            HStack(spacing: 8) {
                if wholePlay.isPreparing {
                    ProgressView()
                    Text("Getting it ready…")
                } else {
                    Image(systemName: isThisNotePlaying ? "pause.fill" : "play.fill").accessibilityHidden(true)
                    Text(isThisNotePlaying ? "Pause" : (isThisNoteOpen ? "Resume" : "Play note"))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(recorder.phase != .idle || wholePlay.isPreparing)
        .accessibilityHint("Plays this whole note, one take after another")
        .accessibilityIdentifier("spokenNote.play")
    }

    private func refreshWholeTimeline() {
        guard let note = recorder.snapshot?.note, let folder = recorder.noteFolder else { return }
        wholePlay.refreshTimeline(note: note, noteFolder: folder)
    }

    private var recordButton: some View {
        Button {
            if recorder.phase == .recording {
                recorder.stop()
            } else {
                // A sentence that is playing, or starting, hands the audio session back before recording takes it. The
                // screen is busy from this tap on, so a second tap or a sentence tap can't slip in meanwhile.
                wholePlay.abandon() // a note still getting ready must not start over the take
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
        .disabled(recorder.isBusy || wholePlay.isPreparing)
        .accessibilityIdentifier("spokenNote.record")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
