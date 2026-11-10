import SwiftUI

/// Side by side only while every child fits on one line each; otherwise one above the other (#1939, #3897).
///
/// At accessibility text sizes it is always a column (#1939). Below that, `ViewThatFits` tries the row first with
/// every label held to one line, and falls back to the column when the labels don't fit side by side. So a pair of
/// long buttons, or three of them, never wrap a word inside a narrow button well before the accessibility sizes, on
/// any width of phone or window. A row whose labels fit looks as it always did.
///
/// A row that holds free text meant to wrap or truncate beside a short control (a Margin's words, an episode title)
/// passes `wrapsText: true` and keeps the old rule: a row until the accessibility sizes. Each such row is named in
/// `scripts/tests/test_adaptive_stack_fit.py`, so a new one is a decision, not a default. A row whose children keep
/// state that a swap would lose (a player, an open menu) must opt out too: `ViewThatFits` rebuilds its children when
/// it switches between the row and the column.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let verticalAlignment: VerticalAlignment
    private let spacing: CGFloat?
    private let wrapsText: Bool
    private let content: Content

    init(
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        wrapsText: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.verticalAlignment = alignment
        self.spacing = spacing
        self.wrapsText = wrapsText
        self.content = content()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            column
        } else if wrapsText {
            row
        } else {
            ViewThatFits(in: .horizontal) {
                row.lineLimit(1)
                column
            }
        }
    }

    private var row: some View {
        HStack(alignment: verticalAlignment, spacing: spacing) { content }
            .environment(\.adaptiveStackIsColumn, false)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .environment(\.adaptiveStackIsColumn, true)
    }
}

private struct AdaptiveStackIsColumnKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside an `AdaptiveStack` that is laid out as a column, where an `AdaptiveSpacer` has nothing to push.
    var adaptiveStackIsColumn: Bool {
        get { self[AdaptiveStackIsColumnKey.self] }
        set { self[AdaptiveStackIsColumnKey.self] = newValue }
    }
}

/// The gap that pushes the next control to the trailing edge in an `AdaptiveStack`'s side-by-side layout. When the
/// stack is a column (accessibility sizes, or labels that don't fit side by side) a flexible spacer would only add
/// height, so it draws nothing (#3723, #3897).
struct AdaptiveSpacer: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.adaptiveStackIsColumn) private var isColumn
    var minLength: CGFloat?

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize && !isColumn { Spacer(minLength: minLength) }
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
