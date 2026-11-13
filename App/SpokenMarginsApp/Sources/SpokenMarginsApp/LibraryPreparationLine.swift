import SwiftUI

/// The Library's one-line entry to Preparing Audio (#3764, #3775). It sits in the Library list's always-present top
/// row, so it must take the height its text needs: the text wraps at large Dynamic Type sizes and the row grows with it,
/// instead of being cut off above the items below (#3775).
struct LibraryPreparationLine: View {
    let line: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(line, systemImage: "waveform.badge.magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.offlineRendering.button")
    }
}
