import SwiftUI
import SessionKit

/// At accessibility text sizes the pinned playback dock scrolls inside a bounded height, so the Now view keeps its
/// room (#1933). At every other size the dock is returned untouched.
extension View {
    @ViewBuilder
    func boundedScrollDock(_ isActive: Bool) -> some View {
        if isActive {
            modifier(PlaybackBoundedDock())
        } else {
            self
        }
    }
}

private struct PlaybackBoundedDock: ViewModifier {
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PlaybackDockHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )
        }
        // When the dock is taller than its cap, the transport and Add a Margin rows (the last ones) stay in view
        // and the pane switch scrolls off the top.
        .defaultScrollAnchor(.bottom)
        .onPreferenceChange(PlaybackDockHeightPreferenceKey.self) { contentHeight = $0 }
        .containerRelativeFrame(.vertical, alignment: .bottom) { container, _ in
            CGFloat(BoundedDockHeight.height(content: Double(contentHeight), container: Double(container)))
        }
        .background(AppColors.listeningBackground)
    }
}

private struct PlaybackDockHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
