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

                    if let parent = model.replyCaptureParent {
                        Label("Replying to \(model.conversationTitle(parent))", systemImage: "arrowshape.turn.up.left")
                        Text(parent.transcript).font(.caption).lineLimit(3)
                    }
                    TextEditor(text: text)
                        .font(.body)
                        .foregroundStyle(AppColors.text)
                        .scrollContentBackground(.hidden)
                        .focused($isEditing)
                        .frame(minHeight: 100)
                        .overlay(alignment: .topLeading) {
                            if draft.text.isEmpty {
                                Text("What do you want to remember?")
                                    .foregroundStyle(AppColors.secondaryText)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("Your Margin")
                        .accessibilityIdentifier("writtenMargin.text")

                    if let error = model.lastError {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Your draft is still here. Try saving again.", systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                            DisclosureGroup("Details") { Text(error).font(.caption) }
                        }
                        .foregroundStyle(AppColors.dangerText)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .background(AppColors.bone)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button {
                        model.saveWrittenMargin(text: draft.text)
                    } label: {
                        Label(draft.priorWasPlaying ? "Save & resume" : "Save Margin", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("writtenMargin.save.button")
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(AppColors.bone)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("writtenMargin.screen")
                .navigationTitle("Write a Margin")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: requestCancel)
                            .accessibilityIdentifier("writtenMargin.cancel.button")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isEditing {
                            Button("Done") { isEditing = false }
                                .accessibilityIdentifier("writtenMargin.keyboard.done")
                        }
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
            }
        }
        .tint(AppColors.evergreen)
    }

    private func requestCancel() {
        if model.writtenMarginDraft?.text.isEmpty == false {
            confirmsDiscard = true
        } else {
            model.cancelWrittenMargin()
        }
    }
}
