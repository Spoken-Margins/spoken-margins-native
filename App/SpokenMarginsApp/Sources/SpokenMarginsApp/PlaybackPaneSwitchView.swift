import SessionKit
import SwiftUI

/// Presentation only: selecting a pane never navigates or changes the player's state.
enum PlaybackPane: String, CaseIterable {
    case now = "Now"
    case timeline = "Timeline"
    case margins = "Margins"

    var symbol: String {
        switch self {
        case .now: "play.circle"
        case .timeline: "list.bullet.rectangle"
        case .margins: "quote.bubble"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .now: "playback.now.button"
        case .timeline: "playback.timeline.button"
        case .margins: "playback.margins.button"
        }
    }
}

struct PlaybackPaneSwitchView: View {
    @Binding var selection: PlaybackPane
    /// Margins a friend sent on this item. The Margins tab says so (#3059), in words and a number.
    var receivedMarginCount = 0

    var body: some View {
        PaneSwitchControl(
            panes: PlaybackPane.allCases,
            selection: $selection,
            symbol: { $0.symbol },
            title: { title(for: $0) },
            accessibilityTitle: { accessibilityTitle(for: $0) },
            identifier: { $0.accessibilityIdentifier },
            badge: { pane in
                // Icon only at accessibility sizes, so the count rides beside the Margins icon (#3059).
                pane == .margins ? PlaybackMarginsTabLabel.countText(receivedCount: receivedMarginCount) : nil
            },
            groupLabel: "Playback view",
            groupIdentifier: "playback.viewSwitch")
    }

    private func title(for pane: PlaybackPane) -> String {
        pane == .margins ? PlaybackMarginsTabLabel.title(receivedCount: receivedMarginCount) : pane.rawValue
    }

    private func accessibilityTitle(for pane: PlaybackPane) -> String {
        pane == .margins ? PlaybackMarginsTabLabel.accessibilityLabel(receivedCount: receivedMarginCount) : pane.rawValue
    }
}

/// The segmented pane switch the playback screen draws, for any set of panes (the live session reuses it).
/// Presentation only. Every slot is a 44 pt target.
struct PaneSwitchControl<Pane: Hashable>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let panes: [Pane]
    @Binding var selection: Pane
    let symbol: (Pane) -> String
    let title: (Pane) -> String
    let accessibilityTitle: (Pane) -> String
    let identifier: (Pane) -> String
    var badge: (Pane) -> String? = { _ in nil }
    let groupLabel: String
    let groupIdentifier: String

    /// The icon-only slots draw the selected pane's symbol filled, a shape cue that costs no width (#3735).
    private func symbolName(for pane: Pane) -> String {
        let name = symbol(pane)
        return selection == pane && !name.hasSuffix(".fill") ? name + ".fill" : name
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(panes, id: \.self) { pane in
                Button { selection = pane } label: {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            HStack(spacing: 4) {
                                Image(systemName: symbolName(for: pane))
                                if let count = badge(pane) {
                                    Text(count)
                                }
                            }
                        } else {
                            // A count must not truncate at large (non-accessibility) sizes on a small phone.
                            Text(title(pane)).minimumScaleFactor(0.8)
                        }
                    }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selection == pane ? Color.playbackSegment(PlaybackSegmentPalette.fill, alpha: PlaybackSegmentPalette.paneSelectedFillAlpha) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        // A second cue that needs no hue and no width: a short bar under the selected words (#3735).
                        // An overlay, so the centred title and symbol don't move and the slot stays 44 pt tall.
                        .overlay(alignment: .bottom) {
                            if selection == pane {
                                Capsule()
                                    .fill(Color.playbackSegment(PlaybackSegmentPalette.selectedLabel))
                                    .frame(width: 20, height: 3)
                                    .padding(.bottom, 5)
                                    .accessibilityHidden(true)
                            }
                        }
                        // A plain button takes taps only on what it draws, so an unselected pane was a target the
                        // size of its word (#430). The whole slot is the target.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.playbackSegment(selection == pane ? PlaybackSegmentPalette.selectedLabel : PlaybackSegmentPalette.unselectedLabel))
                .accessibilityLabel(accessibilityTitle(pane))
                .accessibilityIdentifier(identifier(pane))
                .accessibilityAddTraits(selection == pane ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.playbackSegment(PlaybackSegmentPalette.fill, alpha: PlaybackSegmentPalette.trayAlpha), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupLabel)
        .accessibilityIdentifier(groupIdentifier)
    }
}

extension Color {
    /// A colour of `PlaybackSegmentPalette`, drawn at `alpha`: the same colour on both planes, since the playback plate
    /// is the same in light and dark (#3735).
    static func playbackSegment(_ rgb: AppDynamicRGB, alpha: Double = 1) -> Color {
        AppColors.dynamicColor(rgb).opacity(alpha)
    }
}
