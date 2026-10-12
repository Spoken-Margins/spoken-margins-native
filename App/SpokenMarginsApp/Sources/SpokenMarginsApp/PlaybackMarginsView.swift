import SwiftUI
import SessionKit

/// One source-ordered list of this item's own and shared Margins inside the playback shell.
struct PlaybackMarginsView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var filter: PlaybackMarginsList.Filter = .all
    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?

    var body: some View {
        let own = model.marginRows
            .filter { $0.interjection.itemId == model.selectedItem.id && $0.interjection.status == "active" }
        let shared = model.sharedMarginRows.filter { $0.layer.itemId == model.selectedItem.id && $0.layer.deletedAt == nil }
        let entries = MarginCollection.Entries(
            privateRows: own.map { .init(interjection: $0.interjection, itemTitle: $0.itemTitle,
                                        sessionDate: $0.sessionDate, place: $0.place) },
            sharedRows: shared.map { .init(interjection: $0.interjection, layer: $0.layer, itemTitle: $0.itemTitle) }
        )
        let rows = PlaybackMarginsList.rows(itemID: model.selectedItem.id, entries: entries, filter: filter)
        let counts = PlaybackMarginsList.counts(itemID: model.selectedItem.id, entries: entries)
        let ownByID = Dictionary(own.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sharedByID = Dictionary(shared.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(model.selectedItem.title)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.watchSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                PlaybackMarginsFilterView(selection: $filter)
                Text("Margins: \(visibleCount(counts))")
                    .font(.caption)
                    .foregroundStyle(AppColors.watchSecondary)
                    .accessibilityIdentifier("playback.margins.count")
                if rows.isEmpty {
                    Text(counts.all == 0 ? "No Margins yet. Record or write one using the controls below." : "No Margins in this filter.")
                        .foregroundStyle(AppColors.watchSecondary)
                }
                ForEach(rows) { entry in
                    if entry.origin == .own, let row = ownByID[entry.id] {
                        PlaybackMarginRowView(title: row.preview, detail: row.placeDescription(),
                            isShared: false, identifier: "margins.row.\(row.id)",
                            showDetails: { selectedMargin = row }, play: { _ = model.playMarginMoment(row) })
                    } else if entry.origin == .shared, let row = sharedByID[entry.id] {
                        PlaybackMarginRowView(title: row.interjection.approvedTranscript,
                            detail: "\(row.collectionLabel) · \(row.positionDescription)",
                            isShared: true, identifier: "margins.shared.row.\(row.id)",
                            canPlay: row.interjection.audioPath != nil && SharedMarginPlaybackPosition(row.interjection) != nil,
                            showDetails: { selectedSharedMargin = row }, play: { model.playSharedMarginMoment(row) })
                    }
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

    private func visibleCount(_ counts: PlaybackMarginsList.Counts) -> Int {
        switch filter {
        case .all: counts.all
        case .mine: counts.mine
        case .shared: counts.shared
        }
    }
}
