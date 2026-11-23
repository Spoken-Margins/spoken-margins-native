import SessionKit
import SwiftUI

/// The "Reading voice" row in Listening options (#4640): which voice reads the article, and the button to switch to
/// the other one. Shown only for an article that has the publisher's audio with a ready map; the words come from
/// `PublisherAudioAttribution`, so the button's text, never its icon or a colour, carries the meaning.
struct ListeningOptionsVoiceRow: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var row: PublisherAudioAttribution.VoiceRow?
    @State private var switching = false

    var body: some View {
        Group {
            if let row {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                        Text(row.value)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("playback.readingVoice.value")
                        Text(row.subtitle)
                            .font(.caption2)
                            .foregroundStyle(AppColors.watchSecondary)
                    }
                    Button {
                        Task { await tap(row.button) }
                    } label: {
                        Label(row.button.label, systemImage: row.button.systemImage)
                    }
                    .font(.caption.weight(.bold))
                    .buttonStyle(.bordered)
                    .disabled(switching)
                    .accessibilityIdentifier(row.button == .useAppVoice ? "playback.readingVoice.useAppVoice" : "playback.readingVoice.playPublisherAudio")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppColors.watchControl.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("playback.readingVoice")
            }
        }
        .task(id: model.snapshot.publisherAudioSource) { await reload() }
    }

    private func reload() async {
        row = await model.publisherAudioVoiceRow(itemId: model.selectedItem.id)
    }

    private func tap(_ button: PublisherAudioAttribution.VoiceRowButton) async {
        guard !switching else { return }
        switching = true
        defer { switching = false }
        switch button {
        case .useAppVoice: await model.useAppVoice(itemId: model.selectedItem.id)
        case .playPublisherAudio: await model.playPublisherAudio(itemId: model.selectedItem.id)
        }
        await reload()
    }
}
