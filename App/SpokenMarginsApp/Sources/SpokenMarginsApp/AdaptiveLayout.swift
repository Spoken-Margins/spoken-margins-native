import SwiftUI

/// Side by side at ordinary text sizes, one above the other at accessibility sizes, so paired buttons and
/// label/control rows keep their words instead of squeezing them (#1939).
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let verticalAlignment: VerticalAlignment
    private let spacing: CGFloat?
    private let content: Content

    init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.verticalAlignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: verticalAlignment, spacing: spacing) { content }
        }
    }
}

/// A segmented control reads well with two or three short labels. At accessibility sizes the segments wrap
/// or clip long labels such as "AI Handoff Markdown", so the same picker becomes a menu (#1939).
private struct SegmentedUnlessLargeText: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

extension View {
    func segmentedUnlessLargeText() -> some View {
        modifier(SegmentedUnlessLargeText())
    }
}
