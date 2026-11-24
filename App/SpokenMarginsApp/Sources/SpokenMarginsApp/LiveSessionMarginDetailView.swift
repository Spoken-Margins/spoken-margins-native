import SessionKit
import SwiftUI

/// One Margin taken during a live session, in the playback Margin screen's layout: the words, what kind of Margin it
/// is and where it sits, then what the listener can do with it. A session that is still running has no item to go to
/// and nothing to share yet, so there is no Star, Share, Manage or "Go to this moment" here: only hear the recording,
/// edit the words and delete. The screen holds no session state; the caller gives it the Margin, the position text and
/// what each action does (#3491).
struct LiveSessionMarginDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var audio = LiveSessionMarginAudioModel()
    @State private var isEditing = false
    @State private var draft = ""
    @State private var asksToDelete = false
    /// 40% of this screen, for the photo's height (#2708); measured, not read from the device's screen.
    @State private var photoMaxHeight: CGFloat = 320

    let margin: LiveSessionMargin
    let sessionTitle: String
    /// Where the Margin is, in the unit the session uses; the caller words it (`positionLabel`).
    let position: String
    /// A page number read from the Margin's photo, offered as a checkpoint when nothing else places the Margin (#2708).
    var photoPage: LiveSessionPlace?
    let keepHeardPlace: () -> Void
    let declineHeardPlace: () -> Void
    let saveText: (String) -> Void
    let delete: () -> Void
    /// Pauses whatever the app is playing before the recording starts.
    var pauseOtherAudio: () -> Void = {}
    /// Makes Move to an Item for this Margin alone (#4233 Design 2.3). Nil when it can't move.
    var makeMove: (() -> LiveMarginMoveSheetModel)? = nil
    /// Why it can't move, shown where Move would be. Nil in a saved session, which shows neither.
    var moveUnavailableReason: String? = nil
    var moved: (LiveMarginMoving.Moved) -> Void = { _ in }

    private var kindLine: String {
        let kind = margin.isBlindMark ? "Mark" : margin.isSpoken ? "Spoken Margin" : "Written Margin"
        let title = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? kind : "\(kind) · \(title)"
    }

    private var words: String {
        if margin.isSpoken { return margin.spokenTranscript ?? "Not transcribed yet" }
        return margin.savedText
    }

    private var playButton: some View {
        Button(audio.isPlaying ? "Stop playing" : "Hear my recording", systemImage: audio.isPlaying ? "stop.fill" : "play.fill") {
            guard let path = margin.audioPath else { return }
            audio.toggle(audioPath: path, prepare: pauseOtherAudio)
        }
        .accessibilityIdentifier("marginDetail.playRecording.button")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let photo = margin.validPhoto, let altText = margin.photoAltText {
                        LiveSessionPhotoDetail(photo: photo, altText: altText, maxHeight: photoMaxHeight)
                    }
                    Text(words)
                        .font(.system(.title3, design: .serif))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("marginDetail.words.label")
                    Text(kindLine)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    LabeledContent("Position", value: position)
                    if let note = margin.filingNote {
                        Text("Filed \(note)").font(.caption).foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("marginDetail.filingNote.label")
                    }
                    if let note = margin.clockNote {
                        Text(note).font(.caption).foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("marginDetail.clockNote.label")
                    }
                    if let message = audio.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                if let heard = margin.heardPlace {
                    Section {
                        Text("Heard \u{201C}\(heard.label)\u{201D}. Keep it as a checkpoint?")
                            .font(.subheadline)
                        AdaptiveStack(spacing: 8) {
                            Button("Keep") { keepHeardPlace(); dismiss() }
                                .accessibilityIdentifier("marginDetail.keepPlace.button")
                            Button("No") { declineHeardPlace(); dismiss() }
                                .accessibilityIdentifier("marginDetail.declinePlace.button")
                        }
                        .accessibilityHint("Keep uses \(heard.label) to place the Margins around this one.")
                    }
                }
                if let page = photoPage, margin.heardPlace == nil {
                    Section {
                        Text("Read \u{201C}\(Int(page.value))\u{201D} on the page. Keep it as a checkpoint?")
                            .font(.subheadline)
                            .accessibilityIdentifier("marginDetail.photoPage.label")
                        AdaptiveStack(spacing: 8) {
                            Button("Keep") { keepHeardPlace(); dismiss() }
                                .accessibilityIdentifier("marginDetail.keepPhotoPage.button")
                            Button("No") { declineHeardPlace(); dismiss() }
                                .accessibilityIdentifier("marginDetail.declinePhotoPage.button")
                        }
                        .accessibilityHint("Keep uses \(page.label) to place the Margins around this one.")
                    }
                }
                Section {
                    if margin.isSpoken { playButton }
                    if let makeMove {
                        NavigationLink {
                            LiveMarginMoveSheetHost(make: makeMove, moved: moved)
                        } label: {
                            Label("Move to an Item…", systemImage: "folder")
                        }
                        .simultaneousGesture(TapGesture().onEnded { audio.stop() })
                        .accessibilityIdentifier("marginDetail.move.button")
                    } else if let moveUnavailableReason {
                        Text(moveUnavailableReason)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("marginDetail.moveUnavailable.label")
                    }
                    if isEditing {
                        TextEditor(text: $draft)
                            .frame(minHeight: 120)
                            .accessibilityLabel("Margin words")
                            .accessibilityIdentifier("marginDetail.edit.text")
                        AdaptiveStack(spacing: 8) {
                            Button("Save") {
                                saveText(draft)
                                isEditing = false
                            }
                            .accessibilityIdentifier("marginDetail.edit.save.button")
                            Button("Cancel") { isEditing = false }
                                .accessibilityIdentifier("marginDetail.edit.cancel.button")
                        }
                    } else {
                        Button("Edit", systemImage: "pencil") {
                            draft = margin.text
                            isEditing = true
                        }
                        .accessibilityIdentifier("marginDetail.edit.button")
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { asksToDelete = true }
                        .accessibilityIdentifier("marginDetail.delete.button")
                }
            }
            .buttonStyle(MarginDetailActionButtonStyle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { photoMaxHeight = max(160, $0 * 0.4) }
            .confirmationDialog("Delete this Margin?", isPresented: $asksToDelete, titleVisibility: .visible) {
                Button("Delete Margin", role: .destructive) {
                    audio.stop()
                    isEditing = false // a deleted Margin has no words left to keep
                    delete()
                    dismiss()
                }
                .accessibilityIdentifier("marginDetail.delete.confirm.button")
                Button("Keep Margin", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("marginDetail.screen")
            .navigationTitle("Margin")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("marginDetail.done.button")
                }
            }
            .onDisappear {
                audio.stop()
                // The screen can close without Save or Cancel: Done, a swipe down, or a Lock Screen link that needs the
                // screen. Words being edited are kept then; Cancel has already left editing, so it still discards.
                if isEditing && draft != margin.text { saveText(draft) }
            }
        }
    }
}

/// Move to an Item, owning the sheet's state for as long as it is shown: pushed from a Margin's sheet, or at the root of a
/// sheet of its own (`isRoot`).
struct LiveMarginMoveSheetHost: View {
    @StateObject private var sheet: LiveMarginMoveSheetModel
    let isRoot: Bool
    let moved: (LiveMarginMoving.Moved) -> Void

    init(make: @escaping () -> LiveMarginMoveSheetModel, isRoot: Bool = false, moved: @escaping (LiveMarginMoving.Moved) -> Void) {
        _sheet = StateObject(wrappedValue: make())
        self.isRoot = isRoot
        self.moved = moved
    }

    var body: some View {
        LiveMarginMoveSheet(sheet: sheet, isRoot: isRoot, moved: moved)
    }
}
