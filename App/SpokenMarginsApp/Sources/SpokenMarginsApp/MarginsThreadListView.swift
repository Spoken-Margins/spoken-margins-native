import SessionKit
import SwiftUI

/// The threads of Margins the Margins tab and the arrival preview share (owner's prototype v3): each thread's first
/// Margin, then its replies indented once under a thin rule. Opening a row shows the Margin detail screens the old list
/// used; the star toggles "starred to send" on your own Margins.
struct MarginsThreadListView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let source: MarginsTabSource
    let threads: [MarginsTabList.Thread]
    let mode: MarginsTabRowView.Mode
    let playheadMs: Int
    /// Called after a row's start control is used (the arrival preview closes itself).
    var didStart: () -> Void = {}

    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?

    var body: some View {
        ForEach(threads) { thread in
            VStack(alignment: .leading, spacing: 0) {
                row(thread.root)
                let replies = Array(thread.entries.dropFirst())
                if !replies.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(replies) { row($0) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(AppColors.watchSecondary.opacity(0.24)).frame(width: 1) }
                    .padding(.leading, 14)
                }
            }
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(AppColors.watchSecondary.opacity(0.24)).frame(height: 1) }
            .accessibilityElement(children: .contain)
        }
        .trackedSheet(item: $selectedMargin) { row in
            ExperienceMarginDetailView(row: row).environmentObject(model)
        }
        .trackedSheet(item: $selectedSharedMargin) { row in
            SharedMarginDetailView(row: row).environmentObject(model)
        }
    }

    private func row(_ entry: MarginsTabList.Entry) -> some View {
        MarginsTabRowView(
            entry: entry, mode: mode,
            isPlaying: mode == .playback && source.isPlaying(entry.row, model: model),
            canJump: source.canJump(entry.row),
            direction: MarginsTabList.jumpDirection(entry.row, playheadMs: playheadMs),
            identifier: source.identifier(entry.row),
            showDetails: {
                if let own = source.ownRow(entry.row) { selectedMargin = own }
                else if let shared = source.sharedRow(entry.row) { selectedSharedMargin = shared }
            },
            star: source.ownRow(entry.row).flatMap { .ownMargin($0.interjection, place: .playerMargins, model: model) },
            goesTo: source.goesTo(entry.row), sourceNoun: model.sourceNoun,
            jump: {
                source.jump(to: entry.row, model: model)
                didStart()
            })
    }
}
