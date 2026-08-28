import SwiftUI

struct ExperienceMarginDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    let row: MarginRow

    var body: some View {
        NavigationStack {
            List {
                Section("My Margin") {
                    Text(row.preview).textSelection(.enabled)
                    LabeledContent("Item", value: row.itemTitle)
                    LabeledContent("Attached to", value: row.targetDescription)
                    if row.needsAttention {
                        Label(row.attentionDescription, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppColors.coral)
                    }
                }
                Section("Actions") {
                    Button("Copy with Context", systemImage: "doc.on.doc") {
                        model.copyInterjectionWithContext(row.interjection)
                    }
                    if row.interjection.audioPath != nil {
                        Button(
                            model.playingInterjectionAudioId == row.interjection.id ? "Stop Recording" : "Play Recording",
                            systemImage: model.playingInterjectionAudioId == row.interjection.id ? "stop.fill" : "play.fill"
                        ) {
                            model.toggleInterjectionAudioPlayback(row.interjection)
                        }
                    }
                    if !["transcribed", "complete"].contains(row.interjection.transcriptionStatus) {
                        Button("Retry Transcription", systemImage: "arrow.clockwise") {
                            model.retryInterjectionTranscription(row.interjection)
                        }
                        .disabled(row.interjection.audioPath == nil)
                    }
                    if row.interjection.anchorContextStatus == .unavailable {
                        Button("Retry Context", systemImage: "arrow.clockwise") {
                            model.retryAnchorContext(row.interjection)
                        }
                    }
                    Button("Open in Timeline", systemImage: "list.bullet.rectangle") {
                        dismiss()
                        model.openMarginInTimeline(row)
                    }
                }
            }
            .navigationTitle("Margin")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { model.stopInterjectionAudioPlayback() }
        }
    }
}

