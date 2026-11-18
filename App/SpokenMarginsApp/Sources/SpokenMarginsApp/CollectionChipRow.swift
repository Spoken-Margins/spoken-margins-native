import SwiftUI
import SessionKit

/// The Library's collection chips (#4343, PR 2): **All**, then each collection alphabetically, then **+ New collection**.
/// One row that scrolls sideways, at every text size. The selected chip is filled and carries a checkmark, so colour is
/// never the only sign. A long-press on a collection (or the VoiceOver actions) offers Edit Items, Rename and Delete.
struct CollectionChipRow: View {
    /// A collection chip: the collection and how many Library rows it holds.
    struct Chip: Identifiable {
        let collection: ItemCollection
        let itemCount: Int
        var id: String { collection.id }
    }

    // The selected state is in each chip's label ("Collection, HIST 210, selected, 12 items"), as the Design words it, so
    // no .isSelected trait is added: VoiceOver would say it twice.

    /// The collections in chip order.
    let chips: [Chip]
    /// The selected collection's id; nil is All.
    let selectedID: String?
    let allCount: Int
    let onSelect: (String?) -> Void
    let onNew: () -> Void
    let onEditItems: (ItemCollection) -> Void
    let onRename: (ItemCollection) -> Void
    let onDelete: (ItemCollection) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { onSelect(nil) } label: {
                    chipLabel("All", isSelected: selectedID == nil)
                }
                .accessibilityLabel(LibraryCollectionScope.chipAccessibilityLabel(name: nil, itemCount: allCount, isSelected: selectedID == nil))
                .accessibilityIdentifier("library.collections.all")

                ForEach(chips) { entry in
                    let isSelected = selectedID == entry.id
                    Button { onSelect(entry.id) } label: {
                        chipLabel(entry.collection.name, isSelected: isSelected)
                    }
                    .accessibilityLabel(LibraryCollectionScope.chipAccessibilityLabel(
                        name: entry.collection.name, itemCount: entry.itemCount, isSelected: isSelected))
                    // The same actions for VoiceOver and Switch Control, which can't long-press (#1917, #3730).
                    .accessibilityAction(named: "Edit Items") { onEditItems(entry.collection) }
                    .accessibilityAction(named: "Rename") { onRename(entry.collection) }
                    .accessibilityAction(named: "Delete Collection") { onDelete(entry.collection) }
                    .contextMenu {
                        Button("Edit Items", systemImage: "checklist") { onEditItems(entry.collection) }
                        Button("Rename", systemImage: "pencil") { onRename(entry.collection) }
                        Button("Delete Collection", systemImage: "trash", role: .destructive) { onDelete(entry.collection) }
                    }
                    .accessibilityIdentifier("library.collections.chip.\(entry.id)")
                }

                Button(action: onNew) {
                    chipLabel("New collection", isSelected: false, symbol: "plus")
                }
                .accessibilityLabel("New collection")
                .accessibilityIdentifier("library.collections.new")
            }
            .padding(.vertical, 2)
            // Plain, so a tap lands on the chip it touches and never on the list row around it.
            .buttonStyle(.plain)
        }
        .accessibilityIdentifier("library.collections.row")
    }

    private func chipLabel(_ title: String, isSelected: Bool, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if isSelected {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).accessibilityHidden(true)
            }
            if let symbol {
                Image(systemName: symbol).font(.caption.weight(.bold)).accessibilityHidden(true)
            }
            Text(title).lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isSelected ? AppColors.onEvergreen : AppColors.text)
        .padding(.horizontal, 13)
        .frame(minHeight: TapTarget.minimum)
        .background(isSelected ? AppColors.evergreen : AppColors.panel)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(isSelected ? AppColors.evergreen : AppColors.border) }
        .contentShape(Capsule())
    }
}
