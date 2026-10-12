import SwiftUI
import SessionKit

/// The item's existing own/shared Margin details inside the playback shell. #450 adds filtering.
struct PlaybackMarginsView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?

    var body: some View {
        let own = model.marginRows
            .filter { $0.interjection.itemId == model.selectedItem.id && $0.interjection.status == "active" }
            .sorted { MarginSourceOrder.isOrderedBefore($0.interjection, $1.interjection) }
        let shared = model.sharedMarginRows.filter { $0.layer.itemId == model.selectedItem.id && $0.layer.deletedAt == nil }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(model.selectedItem.title)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.watchSecondary)
                    .lineLimit(1)
                if own.isEmpty && shared.isEmpty {
                    Text("No Margins yet. Record or write one using the controls below.")
                        .foregroundStyle(AppColors.watchSecondary)
                }
                ForEach(own) { row in
                    PlaybackMarginRowView(title: row.preview, detail: row.placeDescription(),
                        isShared: false, identifier: "margins.row.\(row.id)",
                        showDetails: { selectedMargin = row }, play: { _ = model.playMarginMoment(row) })
                }
                ForEach(shared) { row in
                    PlaybackMarginRowView(title: row.interjection.approvedTranscript,
                        detail: "\(row.collectionLabel) · \(row.positionDescription)",
                        isShared: true, identifier: "margins.shared.row.\(row.id)",
                        canPlay: row.interjection.audioPath != nil && SharedMarginPlaybackPosition(row.interjection) != nil,
                        showDetails: { selectedSharedMargin = row }, play: { model.playSharedMarginMoment(row) })
                }
                Button("All Margins and export", systemImage: "square.and.arrow.up", action: model.openMargins)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("playback.margins.collection.button")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("margins.screen")
        .sheet(item: $selectedMargin) { row in
            ExperienceMarginDetailView(row: row).environmentObject(model)
        }
        .sheet(item: $selectedSharedMargin) { row in
            SharedMarginDetailView(row: row).environmentObject(model)
        }
    }
}
