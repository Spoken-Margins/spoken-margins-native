import SessionKit
import SwiftUI

/// The sheet for writing a Margin: an anchor line, a text editor and Save. Playback's written Margin and a live
/// session's written Margin both present it, each with its own model behind the values and closures (#3491).
/// `accessory` is a slot under the editor for what only one of them has, like a live session's place and nudge.
struct MarginWritingSheet<Accessory: View>: View {
    /// The one-line anchor, like "Chapter 3 · 40%", that opens to `anchorDetail`.
    let anchorLabel: String
    let anchorDetail: String
    let anchorAccessibilityLabel: String
    /// Shown above the editor when this Margin answers a shared one (#473).
    let reply: MarginReplyChoice?
    let toggleReply: () -> Void
    @Binding var text: String
    let saveTitle: String
    let error: String?
    /// Runs when Save is tapped with some text in the editor.
    let onSave: () -> Void
    /// Runs when the listener cancels with nothing typed, or confirms the discard.
    let onCancel: () -> Void
    /// What only one caller has, above the editor: a live session's photo and its hint (#2708).
    var lead: AnyView?
    @ViewBuilder let accessory: () -> Accessory

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isEditing: Bool
    @State private var confirmsDiscard = false

    /// Names the friend this Margin answers while it does (#3792), and asks the ordinary question otherwise.
    private var writingPrompt: String { reply?.writingPrompt ?? MarginReplyChoice.rememberPrompt }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                cappedAtAccessibilitySizes {
                    DisclosureGroup {
                        Text(anchorDetail)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Label(anchorLabel, systemImage: "bookmark")
                            .font(.subheadline)
                    }
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityLabel(anchorAccessibilityLabel)
                    .accessibilityIdentifier("writtenMargin.anchor")

                    if let reply {
                        ExperienceReplyChoiceRow(
                            choice: reply, captionColor: AppColors.secondaryText, identifierPrefix: "writtenMargin",
                            switchReply: toggleReply
                        )
                    }
                }

                if let lead { lead }

                TextEditor(text: $text)
                    .font(.body)
                    .foregroundStyle(AppColors.text)
                    .scrollContentBackground(.hidden)
                    .focused($isEditing)
                    .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 140 : 100)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(writingPrompt)
                                .foregroundStyle(AppColors.secondaryText)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Your Margin")
                    .accessibilityHint(writingPrompt)
                    .accessibilityIdentifier("writtenMargin.text")

                accessory()

                if let error {
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
                    saveButton(fillsWidth: true)
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
                        saveButton(fillsWidth: false)
                            .labelStyle(.titleOnly)
                            .fontWeight(.semibold)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Done") { isEditing = false }
                    Spacer()
                    // Save under the thumb too, not only in the far corner (#1980). The bar Save keeps its
                    // identifier; this one has its own so the two stay distinguishable.
                    saveButton(fillsWidth: false, identifier: "writtenMargin.save.keyboard.button")
                        .labelStyle(.titleOnly)
                        .fontWeight(.semibold)
                }
            }
            .alert("Discard this Margin?", isPresented: $confirmsDiscard) {
                Button("Keep writing", role: .cancel) {}
                Button("Discard Margin", role: .destructive, action: onCancel)
            } message: {
                Text("Your words have not been saved.")
            }
            .accessibilityAction(.escape, requestCancel)
            .onAppear { isEditing = true }
            .miniPlayerKeepOut()
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
    private func saveButton(fillsWidth: Bool, identifier: String = "writtenMargin.save.button") -> some View {
        Button {
            onSave()
        } label: {
            Label(saveTitle, systemImage: "checkmark")
                .frame(maxWidth: fillsWidth ? CGFloat.infinity : nil)
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier(identifier)
    }

    private func requestCancel() {
        if !text.isEmpty {
            confirmsDiscard = true
        } else {
            onCancel()
        }
    }
}

extension MarginWritingSheet where Accessory == EmptyView {
    init(
        anchorLabel: String, anchorDetail: String, anchorAccessibilityLabel: String,
        reply: MarginReplyChoice?, toggleReply: @escaping () -> Void, text: Binding<String>, saveTitle: String,
        error: String?, onSave: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
        self.init(
            anchorLabel: anchorLabel, anchorDetail: anchorDetail, anchorAccessibilityLabel: anchorAccessibilityLabel,
            reply: reply, toggleReply: toggleReply, text: text, saveTitle: saveTitle, error: error,
            onSave: onSave, onCancel: onCancel, accessory: { EmptyView() }
        )
    }
}
