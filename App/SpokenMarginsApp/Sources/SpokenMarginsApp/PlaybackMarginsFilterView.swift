import SwiftUI
import SessionKit

/// Local list filtering, using the playback switch's existing button treatment.
struct PlaybackMarginsFilterView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: PlaybackMarginsList.Filter

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(PlaybackMarginsList.Filter.allCases, id: \.self) { option in
                Button { selection = option } label: {
                    // Selected is told by a checkmark as well as a fill that reaches 3:1 against the tray (#1923).
                    HStack(spacing: 4) {
                        if selection == option {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
                        Text(option.title)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(selection == option ? .white.opacity(0.40) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    // A clear chip has nothing to hit-test but its text, so the unselected chips were as small as
                    // their words. The shape gives every chip its whole 44 pt frame to tap (#2900).
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(option.title)
                .accessibilityIdentifier("playback.margins.filter.\(option.rawValue)")
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter Margins")
        .accessibilityIdentifier("playback.margins.filter")
    }
}
