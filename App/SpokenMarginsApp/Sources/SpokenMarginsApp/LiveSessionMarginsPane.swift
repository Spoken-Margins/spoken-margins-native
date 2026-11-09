import SessionKit
import SwiftUI

/// The live session's Margins, in the order and the row style of the playback screen's Margins pane (#3491):
/// earliest source position first, three lines of words, and a tap opens the Margin screen. It opens at the top.
/// A spoken Margin's play button plays its own recording; a written Margin or a Mark has none, so its button is off.
struct LiveSessionMarginsPane: View {
    let session: LiveSession
    let select: (LiveSessionMargin) -> Void
    /// Pauses whatever the app is playing before a recording starts.
    let pauseOtherAudio: () -> Void
    @StateObject private var audio = LiveSessionMarginAudioModel()

    var body: some View {
        let byId = Dictionary(session.margins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = LiveSessionMarginsList.rows(for: session)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(session.title.isEmpty ? "\(session.kind.label) session" : session.title)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.watchSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("Margins: \(session.margins.count)")
                    .font(.caption)
                    .foregroundStyle(AppColors.watchSecondary)
                    .accessibilityIdentifier("liveSession.margins.count")
                if rows.isEmpty {
                    Text("No Margins yet. Record or write one using the controls below.")
                        .foregroundStyle(AppColors.watchSecondary)
                }
                ForEach(rows) { entry in
                    if let margin = byId[entry.id] {
                        row(margin)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveSession.margins.screen")
        .onDisappear { audio.stop() }
    }

    private func row(_ margin: LiveSessionMargin) -> some View {
        var detail = LiveSessionMarginsList.positionLabel(for: margin, in: session)
        if let note = margin.filingNote { detail += " · Filed \(note)" }
        return PlaybackMarginRowView(
            title: title(of: margin), detail: detail,
            isShared: false, identifier: "liveSession.margin.row.\(margin.id)",
            canPlay: margin.isSpoken,
            playLabel: audio.playingId == margin.id ? "Stop playing" : "Hear my recording",
            playHint: margin.isSpoken ? "Plays your recording of this Margin" : "Only a spoken Margin has a recording. Open it to read or edit it.",
            // The Margin screen has its own player, so this pane's stops first: two recordings never play together.
            showDetails: {
                audio.stop()
                select(margin)
            },
            play: {
                guard let path = margin.audioPath else { return }
                audio.toggle(id: margin.id, audioPath: path, prepare: pauseOtherAudio)
            })
    }

    private func title(of margin: LiveSessionMargin) -> String {
        if margin.isSpoken { return margin.spokenTranscript ?? "Spoken Margin, not transcribed yet" }
        return margin.savedText
    }
}
