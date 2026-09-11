import SwiftUI

struct ExperienceMarginDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingNavigation: NavigationIntent?
    @State private var showsManagement = false
    let row: MarginRow

    private enum NavigationIntent { case moment, timeline }
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
                        Button("Retry Transcription", systemImage: "arrow.clockwise") {
                            model.retryInterjectionTranscription(current.interjection)
                        }
                        .disabled(model.isRetryingInterjectionTranscription(current.interjection))
                    }
                    if !current.isWritten, current.interjection.anchorContextStatus == .unavailable {
                        Button("Retry Context", systemImage: "arrow.clockwise") {
                            model.retryAnchorContext(current.interjection)
                        }
                    }
                    Button("Open in Timeline", systemImage: "list.bullet.rectangle") {
                        pendingNavigation = .timeline
                        dismiss()
                    }
                    if model.selectedItem.id == current.interjection.itemId,
                       model.snapshot.sessionId == current.interjection.sessionId {
                        Button("Manage this Margin", systemImage: "ellipsis.circle") { showsManagement = true }
                    }
                }
            }
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
            .sheet(isPresented: $showsManagement) {
                InterjectionDetailView(interjection: current.interjection).environmentObject(model)
            }
            .onDisappear {
                if model.isPlayingInterjectionAudio(current.interjection) { model.stopInterjectionAudioPlayback() }
                switch pendingNavigation {
                case .moment: model.playMarginMoment(current)
                case .timeline: model.openMarginInTimeline(current)
                case nil: break
                }
                pendingNavigation = nil
            }
        }
        .tint(AppColors.evergreen)
    }
}
