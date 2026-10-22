import SwiftUI
import SessionKit

/// A small view into the item's retained source text, driven by the canonical source position.
struct PlaybackLivePassageView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let openReader: (Int) -> Void
    @State private var index: PlaybackLivePassage.Index?
    @State private var sourceIndex = PlaybackLivePassage.SourceIndex(TimelineSourceContent(text: ""))
    @State private var margins: [PlaybackLivePassage.Margin] = []
    @State private var rows: [Row] = []
    @State private var playbackTick = 0 // bumped by each progress tick: the current sentence follows the source offset (#2074)

    private struct Input: Equatable {
        let itemID: String
        let text: String
        let chapters: [Chapter]
    }
    private struct Row: Identifiable {
        let sentence: PlaybackLivePassage.Sentence
        let fragments: [PlaybackLivePassage.Fragment]
        var id: Int { sentence.id }
    }
    private var input: Input {
        Input(itemID: model.selectedItem.id, text: model.selectedItem.text, chapters: model.selectedItem.chapters)
    }
    private var sourceOffset: Int? {
        PlaybackLivePassage.sourceOffset(snapshot: model.snapshot, itemID: model.selectedItem.id,
                                         isNativeAudio: model.selectedItem.isNativeAudio,
                                         textLength: index?.characterCount ?? 0)
    }

    var body: some View {
        let _ = playbackTick
        VStack(spacing: 0) {
            if let sourceOffset, !rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 5) {
                                ForEach(row.sentence.diamonds) { diamond in
                                    Image(systemName: diamond.origin == .own ? "diamond.fill" : "diamond")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(diamond.origin == .own ? AppColors.listeningAccent : Color.blue)
                                        .accessibilityLabel(diamond.origin == .own ? "Your Margin" : "Shared Margin")
                                        .accessibilityIdentifier("playback.now.passage.margin.\(diamond.id)")
                                }
                            }
                            .frame(width: 18)
                            .padding(.top, 12)
                            Button { openReader(sourceOffset) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(row.fragments) { fragment in
                                        if let label = fragment.label {
                                            Text(label).font(.caption.weight(.semibold))
                                        }
                                        Text(fragment.text)
                                            .font(fragment.role == .table ? .body.monospaced() : .body)
                                            .fontWeight(fragment.role == .heading || fragment.role == .title ? .semibold : .regular)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .foregroundStyle(row.sentence.isCurrent ? Color.white : AppColors.watchSecondary)
                                .padding(10)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .background(row.sentence.isCurrent ? AppColors.listeningAccent.opacity(0.18) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .leading) {
                                    if row.sentence.isCurrent {
                                        Capsule().fill(AppColors.listeningAccent).frame(width: 3).padding(.vertical, 5)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(row.sentence.text)
                            .accessibilityHint("Open the full source at the current sentence")
                            .accessibilityValue(row.sentence.isCurrent ? "Current sentence" : "")
                            .accessibilityAddTraits(row.sentence.isCurrent ? .isSelected : [])
                            .accessibilityIdentifier("playback.now.passage.sentence.\(row.id)")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("playback.now.passage")
            }
        }
        .onAppear(perform: rebuild)
        .onChange(of: input) { _, _ in rebuild() }
        .onChange(of: model.selectedItem.timelineSource) { _, value in
            sourceIndex = PlaybackLivePassage.SourceIndex(value)
            renderRows()
        }
        .onChange(of: model.marginRows) { _, _ in updateMargins() }
        .onChange(of: model.sharedMarginRows) { _, _ in updateMargins() }
        .onChange(of: sourceOffset) { _, _ in updateWindow() }
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    private func rebuild() {
        index = PlaybackLivePassage.Index(text: input.text, chapters: input.chapters)
        sourceIndex = PlaybackLivePassage.SourceIndex(model.selectedItem.timelineSource)
        updateMargins()
    }

    private func updateMargins() {
        let length = index?.characterCount ?? 0
        margins = model.marginRows.compactMap {
            PlaybackLivePassage.Margin(own: $0.interjection, itemID: input.itemID, textLength: length)
        } + model.sharedMarginRows.compactMap {
            PlaybackLivePassage.Margin(shared: $0.interjection, layer: $0.layer, itemID: input.itemID, textLength: length)
        }
        updateWindow()
    }

    private func updateWindow() {
        guard let offset = sourceOffset, var updated = index else { rows = []; return }
        let changed = updated.update(offset: offset, margins: margins)
        index = updated
        if changed || rows.isEmpty { renderRows() }
    }

    private func renderRows() {
        rows = index?.window.sentences.map { Row(sentence: $0, fragments: sourceIndex.fragments(for: $0)) } ?? []
    }
}
