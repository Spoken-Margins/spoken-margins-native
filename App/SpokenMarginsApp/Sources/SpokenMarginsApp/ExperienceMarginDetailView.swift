import SessionKit
import SwiftUI
import UIKit

struct ExperienceMarginDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pendingNavigation: NavigationIntent?
    @State private var showsManagement = false
    @State private var actionFeedback: UserFeedbackEvent?
    @State private var markdownFileURL: URL?
    let row: MarginRow

    private enum NavigationIntent { case moment, item }
    private var current: MarginRow { model.marginRows.first { $0.id == row.id } ?? row }

    private var isStarred: Bool { current.interjection.isStarredForSharing == true }

    private var playButton: some View {
        let playing = model.isPlayingInterjectionAudio(current.interjection)
        return Button(playing ? "Stop playing" : "Hear my recording", systemImage: playing ? "stop.fill" : "play.fill") {
            model.toggleInterjectionAudioPlayback(current.interjection)
        }
        .accessibilityIdentifier("marginDetail.playRecording.button")
    }

    private var starButton: some View {
        Button(isStarred ? "Starred" : "Star", systemImage: isStarred ? "star.fill" : "star") {
            model.setMarginStarred(current, starred: !isStarred)
        }
        .accessibilityLabel(isStarred ? "Unstar Margin" : "Star Margin")
        .accessibilityIdentifier("marginDetail.star.button")
    }

    /// Play beside Star: the two things done most often. At accessibility text sizes they stack.
    @ViewBuilder private var primaryActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                if current.canPlayRecording { playButton }
                starButton
            }
        } else {
            HStack(spacing: 8) {
                if current.canPlayRecording { playButton }
                starButton
            }
        }
    }

    /// Rare actions live here so the screen is not a stack of look-alike buttons (#1980).
    private var moreMenu: some View {
        Menu {
            Button("Copy with Context", systemImage: "doc.on.doc") {
                model.copyInterjectionWithContext(current.interjection)
            }
            .buttonStyle(.automatic)
            .accessibilityIdentifier("marginDetail.copyWithContext.button")
            if MarginMarkdownShare.hasNote(current.interjection) {
                Button("Share this Margin", systemImage: "square.and.arrow.up") { // its note as Markdown (#1866 Done when 4)
                    let margin = current.interjection
                    Task { markdownFileURL = await model.prepareMarginMarkdownFileURL(for: [margin], asItem: false) }
                }
                .buttonStyle(.automatic)
                .accessibilityIdentifier("marginDetail.shareMarkdown.button")
            }
            if model.selectedItem.id == current.interjection.itemId,
               model.snapshot.sessionId == current.interjection.sessionId {
                Button("Manage this Margin", systemImage: "slider.horizontal.3") { showsManagement = true }
                    .buttonStyle(.automatic)
                    .accessibilityIdentifier("marginDetail.manage.button")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .foregroundStyle(AppColors.evergreen)
                .background(AppColors.softGreen)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("marginDetail.more.button")
    }

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
                    if let mark = row.cutShort {
                        Label(mark.explanation, systemImage: "scissors")
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("marginDetail.cutShort.label")
                    }
                }
                if current.interjection.replyTo != nil {
                    Section("Replying to") {
                        if let context = model.marginParentContext(of: .local(current.interjection.id), itemId: current.interjection.itemId) {
                            MarginParentContextView(context: context)
                        } else {
                            Text(MarginThreadPresentation.missingParentNote)
                                .foregroundStyle(AppColors.secondaryText)
                                .accessibilityIdentifier("marginDetail.replyMissingParent.label")
                        }
                        Button("Make independent", systemImage: "arrowshape.turn.up.left") {
                            model.setSavedMarginReply(current.interjection, to: nil)
                        }
                        .accessibilityIdentifier("marginDetail.makeIndependent.button")
                    }
                } else if let answered = row.interjection.replyTo {
                    // Switched to independent from this screen: the way back stays until the screen closes (#473).
                    Section("Independent Margin") {
                        Text("This Margin no longer answers a shared Margin.")
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("marginDetail.independent.label")
                        Button("Reply again", systemImage: "arrowshape.turn.up.left.fill") {
                            model.setSavedMarginReply(current.interjection, to: answered)
                        }
                        .accessibilityIdentifier("marginDetail.replyAgain.button")
                    }
                }
                Section {
                    primaryActions
                    if let context = model.marginSourceContext(current) {
                        DisclosureGroup("Context from \(current.targetDescription.lowercased())") {
                            Text(context)
                                .font(.system(.body, design: .serif))
                                .textSelection(.enabled)
                        }
                    }
                    if current.canRetryTranscription {
                        Button(model.isRetryingInterjectionTranscription(current.interjection) ? "Transcribing…" : "Retry Transcription", systemImage: "arrow.clockwise") {
                            model.retryInterjectionTranscription(current.interjection)
                        }
                        .disabled(model.isRetryingInterjectionTranscription(current.interjection))
                    }
                    if current.transcriptWaitsForSpeechRecognition {
                        Button("Open Settings", systemImage: "gearshape") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .accessibilityIdentifier("marginDetail.openSettings.button")
                    }
                    if !current.isWritten, current.interjection.anchorContextStatus == .unavailable {
                        Button(model.isRetryingAnchorContext(current.interjection) ? "Recovering Context…" : "Retry Context", systemImage: "arrow.clockwise") {
                            model.retryAnchorContext(current.interjection)
                        }
                        .disabled(model.isRetryingAnchorContext(current.interjection))
                    }
                    Button("Open Item", systemImage: "doc.text.magnifyingglass") {
                        pendingNavigation = .item
                        dismiss()
                    }
                    moreMenu
                }
            }
            .buttonStyle(MarginDetailActionButtonStyle())
            .fileShareSheet($markdownFileURL)
            .overlay(alignment: .top) {
                if let actionFeedback { UserFeedbackBanner(feedback: actionFeedback).padding(.horizontal, 16) }
            }
            .onChange(of: model.feedbackEvent) { _, event in actionFeedback = event }
            .onDisappear {
                // Having been opened is what clears the mark (#1976); it stays while the note is on screen.
                guard CutShortMargins.shared.clear(sessionId: row.interjection.sessionId, interjectionId: row.interjection.id) else { return }
                model.refreshMarginRows()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("Go to this moment in the source", systemImage: "arrow.turn.down.right") {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("marginDetail.done.button")
                }
            }
            .sheet(isPresented: $showsManagement) {
                InterjectionDetailView(interjection: current.interjection).environmentObject(model)
            }
            .onDisappear {
                if model.isPlayingInterjectionAudio(current.interjection) { model.stopInterjectionAudioPlayback() }
                switch pendingNavigation {
                case .moment: model.playMarginMoment(current)
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
