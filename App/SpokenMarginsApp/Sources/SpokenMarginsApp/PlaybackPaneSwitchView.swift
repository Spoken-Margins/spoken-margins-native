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

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlaybackPane.allCases, id: \.self) { pane in
                Button { selection = pane } label: {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize { Image(systemName: pane.symbol) }
                        else { Text(pane.rawValue) }
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
                .accessibilityLabel(pane.rawValue)
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
}
