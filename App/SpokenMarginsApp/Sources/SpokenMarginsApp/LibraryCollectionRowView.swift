import SwiftUI
import SessionKit

/// A collection as one Library row (#3769), shaped like a Following show row: a stacked tile, the name, its count line,
/// ▶ (Play All / Continue / Play Again) and ›. The row adds no line under itself and carries no colour-only state: the
/// count line says how many are unfinished, and an import in progress says "Adding 3 of 24…" next to a spinner.
struct LibraryCollectionRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: LibraryCollectionRow
    let isCurrent: Bool
    let open: () -> Void
    let play: () -> Void
    let addToQueue: () -> Void
    let rename: () -> Void
    let exportMargins: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 12) {
                    tile
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name)
                            .font(.headline)
                            .foregroundStyle(AppColors.text)
                            .multilineTextAlignment(.leading)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        HStack(spacing: 6) {
                            if row.progress.isImporting { ProgressView().controlSize(.mini) }
                            Text(row.progress.detailLine)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.progress.accessibilityLabel)
            .accessibilityHint("Opens the collection.")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityIdentifier("library.collection.\(row.collectionID)")
            playButton
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(AppColors.bone)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(AppColors.evergreen).frame(width: 3)
            }
        }
        .contextMenu {
            Button(LibraryBulkAction.addToQueue.title, systemImage: LibraryBulkAction.addToQueue.symbol, action: addToQueue)
            Button("Export Margins…", systemImage: "square.and.arrow.up", action: exportMargins)
            Button("Rename…", systemImage: "pencil", action: rename)
            Button("Delete Collection…", systemImage: "trash", role: .destructive, action: delete)
        }
        // The same actions for VoiceOver and Switch Control, which can't long-press (#1917).
        .accessibilityActions {
            Button(LibraryBulkAction.addToQueue.title, action: addToQueue)
            Button("Export Margins", action: exportMargins)
            Button("Rename", action: rename)
            Button("Delete Collection", action: delete)
        }
    }

    /// ▶ with its word, "Play All", "Continue" or "Play Again", so what it does is never only an icon. At accessibility
    /// sizes the word leaves the row to the name and stays in what VoiceOver reads.
    private var playButton: some View {
        Button(action: play) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: playSymbol).font(.title2)
                } else {
                    Label(row.playPlan?.label.rawValue ?? LibraryCollectionPlayPlan.Label.start.rawValue, systemImage: playSymbol)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(row.playPlan == nil ? AppColors.secondaryText : AppColors.evergreen)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.playPlan == nil)
        .accessibilityLabel(row.playPlan?.label.accessibilityLabel(name: row.name) ?? "Play all of \(row.name)")
        .accessibilityIdentifier("library.collection.\(row.collectionID).play")
    }

    private var playSymbol: String {
        row.playPlan?.label == .playAgain ? "arrow.counterclockwise.circle.fill" : "play.circle.fill"
    }

    private var tile: some View {
        Image(systemName: "rectangle.stack.fill")
            .font(.title2)
            .foregroundStyle(AppColors.evergreen)
            .frame(width: 56, height: 56)
            .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityHidden(true)
    }
}
