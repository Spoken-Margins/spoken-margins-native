import SwiftUI
import SessionKit

struct ExperienceMarginDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingNavigation: NavigationIntent?
    @State private var replyNode: MarginConversationSnapshot?
    @State private var replyNodes: [MarginConversationSnapshot] = []
    @State private var showsManagement = false
    @State private var actionFeedback: UserFeedbackEvent?
    let row: MarginRow

    private enum NavigationIntent { case moment, item, context, conversation, replyVoice, replyWritten, archivedConversation }
    private var current: MarginRow { model.marginRows.first { $0.id == row.id } ?? row }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(current.fullText)
                        .font(.system(.title3, design: .serif))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(current.isWritten ? "Written Margin" : "Voice Margin") · \(current.itemTitle)")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    LabeledContent("Attached to", value: current.targetDescription)
                    LabeledContent("Position", value: InterjectionPositionPresentation.detailDescription(for: current.interjection, durationMs: nil))
                    if current.needsAttention {
                        Label(current.attentionDescription, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppColors.coral)
                    }
                }
                Section("Conversation") {
                    LabeledContent("Responding to", value: model.responseTargetTitle(current.interjection))
                    Button("Response & listening context", systemImage: "text.quote") {
                        model.editConversationContext(current.interjection)
                    }
                    Button("Voice reply", systemImage: "mic") { pendingNavigation = .replyVoice; dismiss() }
                    Button("Written reply", systemImage: "square.and.pencil") { pendingNavigation = .replyWritten; dismiss() }
                }.disabled(current.interjection.targetType != .item)
                ConversationRepliesSection(reference: current.interjection.conversation?.reference) { nodes, written in
                    replyNodes = nodes; pendingNavigation = written ? .replyWritten : .replyVoice; dismiss()
                } listen: { node in
                    replyNode = node; pendingNavigation = .archivedConversation; dismiss()
                }
                Section {
                    if let context = model.marginSourceContext(current) {
                        DisclosureGroup("Context from \(current.targetDescription.lowercased())") {
                            Text(context)
                                .font(.system(.body, design: .serif))
                                .textSelection(.enabled)
                        }
                    }
                    Button("Copy with Context", systemImage: "doc.on.doc") {
                        model.copyInterjectionWithContext(current.interjection)
                    }
                    if current.canPlayRecording {
                        Button(
                            model.isPlayingInterjectionAudio(current.interjection) ? "Stop Recording" : "Play Recording",
                            systemImage: model.isPlayingInterjectionAudio(current.interjection) ? "stop.fill" : "play.fill"
                        ) { model.toggleInterjectionAudioPlayback(current.interjection) }
                    }
                    if current.canRetryTranscription {
                        Button(model.isRetryingInterjectionTranscription(current.interjection) ? "Transcribing…" : "Retry Transcription", systemImage: "arrow.clockwise") {
                            model.retryInterjectionTranscription(current.interjection)
                        }
                        .disabled(model.isRetryingInterjectionTranscription(current.interjection))
                    }
                    if !current.isWritten, current.interjection.anchorContextStatus == .unavailable {
                        Button(model.isRetryingAnchorContext(current.interjection) ? "Recovering Context…" : "Retry Context", systemImage: "arrow.clockwise") {
                            model.retryAnchorContext(current.interjection)
                        }
                        .disabled(model.isRetryingAnchorContext(current.interjection))
                    }
                    if current.interjection.targetType == .item {
                        Button("Play Margin", systemImage: "play.fill") {
                            pendingNavigation = .conversation
                            dismiss()
                        }
                        Button("Play with context", systemImage: "backward.end.alt") {
                            pendingNavigation = .context
                            dismiss()
                        }
                    }
                    Button("Open Item", systemImage: "doc.text.magnifyingglass") {
                        pendingNavigation = .item
                        dismiss()
                    }
                    if model.selectedItem.id == current.interjection.itemId,
                       model.snapshot.sessionId == current.interjection.sessionId {
                        Button("Manage this Margin", systemImage: "ellipsis.circle") { showsManagement = true }
                    }
                }
            }
            .buttonStyle(MarginDetailActionButtonStyle())
            .overlay(alignment: .top) {
                if let actionFeedback { UserFeedbackBanner(feedback: actionFeedback).padding(.horizontal, 16) }
            }
            .onChange(of: model.feedbackEvent) { _, event in actionFeedback = event }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("Play this moment", systemImage: "play.fill") {
                    pendingNavigation = .moment
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("marginDetail.playMoment.button")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(AppColors.bone)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("marginDetail.screen")
            .navigationTitle("Margin")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.setMarginStarred(current, starred: current.interjection.isStarredForSharing != true)
                    } label: {
                        Image(systemName: current.interjection.isStarredForSharing == true ? "star.fill" : "star")
                    }
                    .accessibilityLabel(current.interjection.isStarredForSharing == true ? "Unstar Margin" : "Star Margin")
                    .accessibilityIdentifier("marginDetail.star.button")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(item: $model.conversationEditorNote) { note in
                ConversationContextEditor(note: note).environmentObject(model)
            }
            .sheet(isPresented: $showsManagement) {
                InterjectionDetailView(interjection: current.interjection).environmentObject(model)
            }
            .onDisappear {
                if model.isPlayingInterjectionAudio(current.interjection) { model.stopInterjectionAudioPlayback() }
                switch pendingNavigation {
                case .archivedConversation: if let replyNode { model.playConversationSnapshot(replyNode) }
                case .replyVoice, .replyWritten:
                    if !replyNodes.isEmpty {
                        model.beginArchivedReply(to: replyNodes, written: pendingNavigation == .replyWritten)
                    }
                    else { model.beginReply(to: current.interjection, written: pendingNavigation == .replyWritten) }
                case .moment: model.playMarginMoment(current)
                case .context: model.playConversationMargin(current.interjection, withContext: true)
                case .conversation: model.playConversationMargin(current.interjection, withContext: false)
                case .item: model.openItem(id: current.interjection.itemId)
                case nil: break
                }
                pendingNavigation = nil
            }
        }
        .tint(AppColors.evergreen)
    }
}

/// Keep activation visible after a quick tap, including when the action performs
/// synchronous model work. A completion toast is a separate acknowledgement.
private struct MarginDetailActionButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MarginDetailActionButton(configuration: configuration)
    }
}

private struct MarginDetailActionButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @State private var activated = false

    var body: some View {
        Button {
            guard !activated else { return }
            activated = true
            Task { @MainActor in
                // Let the highlighted frame render before copy, playback or dismissal.
                try? await Task.sleep(for: .milliseconds(80))
                configuration.trigger()
                try? await Task.sleep(for: .milliseconds(350))
                activated = false
            }
        } label: {
            configuration.label
        }
        .buttonStyle(MarginDetailPressedButtonStyle(activated: activated))
    }
}

private struct MarginDetailPressedButtonStyle: ButtonStyle {
    let activated: Bool

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.isPressed || activated
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .foregroundStyle(highlighted ? AppColors.onEvergreen : AppColors.evergreen)
            .background(highlighted ? AppColors.evergreen : AppColors.softGreen)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(highlighted ? 0.75 : 1)
    }
}
