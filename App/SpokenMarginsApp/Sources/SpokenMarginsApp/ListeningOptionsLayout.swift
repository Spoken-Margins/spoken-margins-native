import SwiftUI

/// The column Listening options draws its rows in (#5333).
///
/// At the largest text size one row came out wider than the screen. A vertical `ScrollView` lets its content take the
/// width it asks for and centres it, so the whole column was laid out wider than the sheet and every row lost its
/// leading words ("ote audio", "ong pauses are"). The column is now exactly as wide as the sheet less its margins: rows
/// that wrap always fit, and a row that still can't fit runs past the trailing edge alone instead of pushing the rest off
/// the leading one.
struct ListeningOptionsColumn<Content: View>: View {
    static var margin: CGFloat { 20 }

    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                max(length - Self.margin * 2, 0)
            }
            .padding(Self.margin)
        }
    }
}

/// The bottom row of Listening options: Details, Timeline and Export (#5333).
///
/// The row is two fixed 48-point icons beside a Timeline label that never wraps. At accessibility text sizes that is
/// wider than a phone, so it then stacks: Timeline across the top, Details and Export under it. Identifiers and labels
/// are the same in both layouts.
struct ListeningOptionsActionDock: View {
    let exportDisabled: Bool
    let showDetails: () -> Void
    let showTimeline: () -> Void
    let showExport: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                detailsButton
                timelineButton(fixedWidth: true)
                exportButton
            }
            VStack(spacing: 8) {
                timelineButton(fixedWidth: false)
                HStack(spacing: 8) {
                    detailsButton
                    Spacer(minLength: 0)
                    exportButton
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(.white)
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var detailsButton: some View {
        Button(action: showDetails) {
            Image(systemName: "info.circle")
                .frame(width: 48, height: 48)
        }
        .accessibilityLabel("Details")
        .accessibilityIdentifier("playback.item.button")
    }

    /// In the row the label keeps its one line and sets the row's width; stacked it takes the column's width and may
    /// shrink a little on the narrowest phones rather than break "Timeline" mid-word.
    @ViewBuilder
    private func timelineButton(fixedWidth: Bool) -> some View {
        Button(action: showTimeline) {
            if fixedWidth {
                Label("Timeline", systemImage: "list.bullet.rectangle")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                Label("Timeline", systemImage: "list.bullet.rectangle")
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .accessibilityIdentifier("playback.timeline.button")
    }

    private var exportButton: some View {
        Button(action: showExport) {
            Image(systemName: "doc.text")
                .frame(width: 48, height: 48)
        }
        .disabled(exportDisabled)
        .accessibilityLabel("Export")
        .accessibilityIdentifier("playback.export.button")
    }
}
