import SwiftUI
import SessionKit

/// The podcast's source-clock neighbourhood, backed by the already-published Margin collections.
struct PlaybackNowView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?
    @State private var playbackTick = 0 // bumped by each progress tick: the rows count down on the playhead (#2074)

    var body: some View {
        let _ = playbackTick
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

        // The scene under the playhead on the listener's own clock (#1629). Only while the source is playing:
        // a generated response has its own clock, and another item's map must never show here.
        let sceneSummary = isSourceClock
            ? SceneSummarySelector.summary(at: model.snapshot.currentMediaTimeMs ?? 0, in: model.selectedItem.listeningMapSummarySpans)
            : nil

        VStack(alignment: .leading, spacing: 8) {
            if let sceneSummary {
                Text("In this scene")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.watchSecondary)
                    .accessibilityAddTraits(.isHeader)
                Text(sceneSummary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("playback.now.sceneSummary")
                    .padding(.bottom, 12)
            }
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
                        detail: "\(row.collectionLabel) · \(entry.isApproximate ? SharedMarginPlacementWording.approximate : row.positionDescription)",
                        countdown: entry.countdown, isShared: true, identifier: "playback.now.margin.\(row.id)",
                        canPlay: row.interjection.audioPath != nil,
                        showDetails: { selectedSharedMargin = row }, play: { model.playSharedMarginMoment(row) })
                }
            }
        }
        // The player paints its own dark green whatever the system appearance,
        // so text that sets no style must default to white here, not `.primary`.
        .foregroundStyle(.white)
        .accessibilityIdentifier("playback.now.margins")
        .sheet(item: $selectedMargin) { row in
            ExperienceMarginDetailView(row: row).environmentObject(model)
        }
        .sheet(item: $selectedSharedMargin) { row in
            SharedMarginDetailView(row: row).environmentObject(model)
        }
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }
}
