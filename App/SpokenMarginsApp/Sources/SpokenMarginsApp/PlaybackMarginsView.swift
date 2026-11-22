import SwiftUI
import SessionKit

/// The playback screen's Margins tab (owner's prototype v3, part of #3216): every Margin of this item, own and
/// friends', in threads by place in the episode, with the filter, the Autoplay menu and "Jump to this Margin" on each
/// row. The list and its rules are `MarginsControlCenter` and `MarginsTabList`; this only draws them.
struct PlaybackMarginsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: Gate1AppModel
    @State private var filter: PlaybackMarginsList.Filter = .all
    @State private var playbackTick = 0 // the jump icons follow the playhead (#2074)

    var body: some View {
        let _ = playbackTick
        let source = MarginsTabSource(model: model)
        let threads = MarginsTabList.threads(source.rows)
        let shown = MarginsTabList.filter(threads, filter)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(model.selectedItem.title)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.watchSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.tail)
                controlsLine(hasFriendsMargins: source.rows.contains { !$0.isYours })
                Text("Margins: \(shown.reduce(0) { $0 + $1.entries.count })")
                    .font(.caption)
                    .foregroundStyle(AppColors.watchSecondary)
                    .accessibilityIdentifier("playback.margins.count")
                if shown.isEmpty {
                    Text(source.rows.isEmpty ? "No Margins yet. Record or write one using the controls below." : "No Margins in this filter.")
                        .foregroundStyle(AppColors.watchSecondary)
                }
                MarginsThreadListView(
                    source: source, threads: shown, mode: .playback,
                    playheadMs: model.snapshot.currentMediaTimeMs ?? 0)
                Button(action: model.openMargins) {
                    Label("All Margins and export", systemImage: "quote.bubble").frame(minHeight: 44).contentShape(Rectangle())
                }
                .tint(AppColors.listeningAccent)
                .accessibilityIdentifier("playback.margins.collection.button")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("margins.screen")
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    /// The filter, and the Autoplay menu at the end of the same line. At accessibility sizes they stack.
    /// The menu shows when the list has a friend's Margin: the same rows the tab draws, so a friend's row is never shown
    /// without it (lane T4 on 5bdcb06, step 4, found it missing while Sam's and Rae's rows showed).
    @ViewBuilder
    private func controlsLine(hasFriendsMargins: Bool) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            PlaybackMarginsFilterView(selection: $filter)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
            if hasFriendsMargins {
                Spacer(minLength: 0)
                MarginsAutoplayMenu()
            }
        }
    }
}

/// "Autoplay Unheard ▾": Unheard Margins, All Margins or Off, on the existing auto-play path
/// (`Gate1AppModel.setMarginsAutoplay`). Only shown when a friend's Margins are on the item, as the Now tab's switch is.
struct MarginsAutoplayMenu: View {
    @EnvironmentObject private var model: Gate1AppModel
    // Read here so the menu redraws when the preference changes; the model reads the same key.
    @AppStorage(Gate1AppModel.marginsAutoplayIncludesHeardKey) private var includesHeard = false

    var body: some View {
        let current = MarginsAutoplaySetting.current(autoPlayOn: model.importedCommentaryAutoPlayEnabled, includesHeard: includesHeard)
        Menu {
            Picker(MarginsControlCenter.Autoplay.menuTitle, selection: Binding(
                get: { current },
                set: { model.setMarginsAutoplay($0) })) {
                ForEach(MarginsControlCenter.Autoplay.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text("Autoplay").foregroundStyle(AppColors.watchSecondary)
                Text(current.shortTitle).fontWeight(.semibold).foregroundStyle(.white)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(AppColors.watchSecondary)
            }
            .font(.footnote)
            .lineLimit(1)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Autoplay, \(current.title)")
        .accessibilityIdentifier("playback.margins.autoplay")
    }
}
