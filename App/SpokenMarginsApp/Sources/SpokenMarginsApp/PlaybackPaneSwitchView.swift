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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: PlaybackPane
    /// Margins a friend sent on this item. The Margins tab says so (#3059), in words and a number.
    var receivedMarginCount = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlaybackPane.allCases, id: \.self) { pane in
                Button { selection = pane } label: {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            // Icon only at these sizes, so the count rides beside the Margins icon (#3059).
                            HStack(spacing: 4) {
                                Image(systemName: pane.symbol)
                                if pane == .margins,
                                   let count = PlaybackMarginsTabLabel.countText(receivedCount: receivedMarginCount) {
                                    Text(count)
                                }
                            }
                        } else {
                            // A count must not truncate at large (non-accessibility) sizes on a small phone.
                            Text(title(for: pane)).minimumScaleFactor(0.8)
                        }
                    }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selection == pane ? .white.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        // A plain button takes taps only on what it draws, so an unselected pane was a target the
                        // size of its word (#430). The whole slot is the target.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(accessibilityTitle(for: pane))
                .accessibilityIdentifier(pane.accessibilityIdentifier)
                .accessibilityAddTraits(selection == pane ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback view")
        .accessibilityIdentifier("playback.viewSwitch")
    }

    private func title(for pane: PlaybackPane) -> String {
        pane == .margins ? PlaybackMarginsTabLabel.title(receivedCount: receivedMarginCount) : pane.rawValue
    }

    private func accessibilityTitle(for pane: PlaybackPane) -> String {
        pane == .margins ? PlaybackMarginsTabLabel.accessibilityLabel(receivedCount: receivedMarginCount) : pane.rawValue
    }
}
