import SessionKit
import SwiftUI

struct ExperienceWrittenMarginScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isEditing: Bool
    @State private var confirmsDiscard = false

    private var text: Binding<String> {
        Binding(
            get: { model.writtenMarginDraft?.text ?? "" },
            set: { model.updateWrittenMarginText($0) }
        )
    }

    var body: some View {
        NavigationStack {
            if let draft = model.writtenMarginDraft {
                VStack(alignment: .leading, spacing: 16) {
                    cappedAtAccessibilitySizes {
                        DisclosureGroup {
                            Text(draft.itemTitle)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        } label: {
                            Label("\(draft.targetDescription) · \(draft.progressPercent)%", systemImage: "bookmark")
                                .font(.subheadline)
                        }
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityLabel("Saved position for \(draft.itemTitle), \(draft.targetDescription), \(draft.progressPercent) percent")
                        .accessibilityIdentifier("writtenMargin.anchor")

                        if let reply = draft.reply {
                            Label(reply.caption, systemImage: "arrowshape.turn.up.left.fill")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("writtenMargin.replyCaption.label")
                        }
                    }

                    TextEditor(text: text)
                        .font(.body)
                        .foregroundStyle(AppColors.text)
                        .scrollContentBackground(.hidden)
                        .focused($isEditing)
                        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 140 : 100)
                        .overlay(alignment: .topLeading) {
                            if draft.text.isEmpty {
                                Text("What do you want to remember?")
                                    .foregroundStyle(AppColors.secondaryText)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("Your Margin")
                        .accessibilityHint("What do you want to remember?")
                        .accessibilityIdentifier("writtenMargin.text")

                    if let error = model.lastError {
                        cappedAtAccessibilitySizes {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Your draft is still here. Try saving again.", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline)
                                DisclosureGroup("Details") { Text(error).font(.caption) }
                            }
                            .foregroundStyle(AppColors.dangerText)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .background(AppColors.bone)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // While the listener is typing, Save lives in the navigation bar
                    // (see the toolbar below) so nothing the listener needs sits where
                    // the keyboard can cover it (#1184).
                    if !isEditing {
                        saveButton(draft, fillsWidth: true)
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(AppColors.bone)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("writtenMargin.screen")
                .announcesScreenChange()
                .navigationTitle("Write a Margin")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: requestCancel)
                            .accessibilityIdentifier("writtenMargin.cancel.button")
                    }
                    if isEditing {
                        ToolbarItem(placement: .confirmationAction) {
                            saveButton(draft, fillsWidth: false)
                                .labelStyle(.titleOnly)
                                .fontWeight(.semibold)
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Button("Done") { isEditing = false }
                        Spacer()
                        // Save under the thumb too, not only in the far corner (#1980). The bar Save keeps its
                        // identifier; this one has its own so the two stay distinguishable.
                        saveButton(draft, fillsWidth: false, identifier: "writtenMargin.save.keyboard.button")
                            .labelStyle(.titleOnly)
                            .fontWeight(.semibold)
                    }
                }
                .alert("Discard this Margin?", isPresented: $confirmsDiscard) {
                    Button("Keep writing", role: .cancel) {}
                    Button("Discard Margin", role: .destructive, action: model.cancelWrittenMargin)
                } message: {
                    Text("Your words have not been saved.")
                }
                .accessibilityAction(.escape, requestCancel)
                .onAppear { isEditing = true }
                .miniPlayerKeepOut()
            }
        }
        .tint(AppColors.evergreen)
    }

    /// At accessibility sizes the saved-position line, the reply caption and an error can take most of the screen, and
    /// with the keyboard up they pushed the editor off it (#1942). They scroll inside a capped area, so the editor keeps
    /// a usable height. At other sizes they sit in the screen as before.
    @ViewBuilder
    private func cappedAtAccessibilitySizes<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: isEditing ? 110 : 220)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            content()
        }
    }

    /// One Save button, built three ways: the bottom bar when the keyboard is down, and the
    /// navigation bar and the keyboard bar while typing. The identifier tells them apart.
    private func saveButton(_ draft: WrittenMarginDraft, fillsWidth: Bool, identifier: String = "writtenMargin.save.button") -> some View {
        Button {
            model.saveWrittenMargin(text: draft.text)
        } label: {
            Label(draft.priorWasPlaying ? "Save & resume" : "Save Margin", systemImage: "checkmark")
                .frame(maxWidth: fillsWidth ? CGFloat.infinity : nil)
        }
        .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier(identifier)
    }

    private func requestCancel() {
        if model.writtenMarginDraft?.text.isEmpty == false {
            confirmsDiscard = true
        } else {
            model.cancelWrittenMargin()
        }
    }
}
