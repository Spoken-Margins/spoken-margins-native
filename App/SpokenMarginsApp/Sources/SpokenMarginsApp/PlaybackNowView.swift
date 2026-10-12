import SwiftUI
import SessionKit

/// The podcast's source-clock neighbourhood, backed by the already-published Margin collections.
struct PlaybackNowView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?

    var body: some View {
        let own = model.marginRows
        let shared = model.sharedMarginRows
        let candidates = own.compactMap { PlaybackNowMargins.Margin(own: $0.interjection, itemID: model.selectedItem.id) }
            + shared.compactMap { PlaybackNowMargins.Margin(shared: $0.interjection, layer: $0.layer, itemID: model.selectedItem.id) }
        // A generated response has its own clock. Never count down episode Margins against it.
        let isSourceClock = model.snapshot.itemId == model.selectedItem.id
            && (model.snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || model.snapshot.targetType == TargetType.browserOwnedMedia.rawValue)
        let rows = isSourceClock ? PlaybackNowMargins.rows(
            playhead: Double(model.snapshot.currentMediaTimeMs ?? 0) / 1_000, margins: candidates
        ) : []

        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby Margins")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.watchSecondary)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(isSourceClock ? "Record or write a Margin as you listen. Your notes and shared Margins appear here." : "Nearby Margins appear while listening to the source.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.watchSecondary)
            }
            ForEach(rows) { entry in
                if let row = own.first(where: { $0.id == entry.id }), entry.origin == .own {
                    PlaybackMarginRowView(title: PlaybackMarginPreview.text(displayText: row.interjection.displayText,
                        cleanedTranscript: row.interjection.cleanedTranscript, transcript: row.interjection.transcript,
                        transcriptionStatus: row.interjection.transcriptionStatus, captureKind: row.interjection.captureKind),
                        detail: row.placeDescription(), countdown: entry.countdown,
                        isShared: false, identifier: "playback.now.margin.\(row.id)",
                        showDetails: { selectedMargin = row }, play: { _ = model.playMarginMoment(row) })
                } else if let row = shared.first(where: { $0.id == entry.id }), entry.origin == .shared {
                    PlaybackMarginRowView(title: row.interjection.approvedTranscript,
                        detail: "\(row.collectionLabel) · \(entry.isApproximate ? "Approximate position" : row.positionDescription)",
                        countdown: entry.countdown, isShared: true, identifier: "playback.now.margin.\(row.id)",
                        canPlay: row.interjection.audioPath != nil,
                        showDetails: { selectedSharedMargin = row }, play: { model.playSharedMarginMoment(row) })
                }
            }
        }
        .accessibilityIdentifier("playback.now.margins")
        .sheet(item: $selectedMargin) { row in
            ExperienceMarginDetailView(row: row).environmentObject(model)
        }
        .sheet(item: $selectedSharedMargin) { row in
            SharedMarginDetailView(row: row).environmentObject(model)
        }
    }
}
