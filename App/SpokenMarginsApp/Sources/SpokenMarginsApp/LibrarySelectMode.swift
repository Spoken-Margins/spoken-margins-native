import SwiftUI
import SessionKit

/// A row while Select is on (#4720), as Mail and Files draw it: a tick circle before the row, and the whole row one tap
/// target that ticks it. The circle's shape changes (empty, ticked), never only its colour. For VoiceOver the row is one
/// element with the selected trait and the "Double-tap to select." hint; the row's own buttons rest while selecting.
struct LibrarySelectableRow<Content: View>: View {
    let isSelected: Bool
    let label: String
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AppColors.evergreen : AppColors.secondaryText)
                    .frame(width: 44, height: 44)
                    .padding(.leading, 4)
                content
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(LibrarySelection.rowAccessibilityHint(isSelected: isSelected))
    }
}

/// The bar of actions at the bottom while Select is on, from `LibraryBulkAction.available`: Add to Queue, Add to
/// Collection, a More menu for the marks (and Remove from Collection inside a collection), and Move to Recently Deleted.
/// With nothing ticked the actions show and are off, as in Files.
struct LibrarySelectActionBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let available: [LibraryBulkAction]
    let insideCollection: Bool
    let perform: (LibraryBulkAction) -> Void

    private var moreActions: [LibraryBulkAction] {
        available.filter { [.markFinished, .markUnfinished, .removeFromCollection].contains($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            barButton(.addToQueue)
            barButton(.addToCollection)
            moreMenu
            barButton(.moveToRecentlyDeleted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(AppColors.panel)
        .overlay(alignment: .top) { Rectangle().fill(AppColors.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.select.actions")
    }

    private func barButton(_ action: LibraryBulkAction) -> some View {
        Button { perform(action) } label: { barLabel(action.title, symbol: action.symbol) }
            .buttonStyle(.plain)
            .disabled(!available.contains(action))
            .foregroundStyle(available.contains(action) ? (action.isDestructive ? AppColors.dangerText : AppColors.evergreen) : AppColors.secondaryText)
            .accessibilityLabel(action.title)
            .accessibilityIdentifier("library.select.\(action.rawValue)")
    }

    private var moreMenu: some View {
        Menu {
            ForEach(moreActions) { action in
                Button(action.title, systemImage: action.symbol) { perform(action) }
            }
        } label: {
            barLabel("More", symbol: "ellipsis.circle")
        }
        .disabled(moreActions.isEmpty)
        .foregroundStyle(moreActions.isEmpty ? AppColors.secondaryText : AppColors.evergreen)
        .accessibilityLabel("More")
        .accessibilityIdentifier("library.select.more")
    }

    /// The icon with its words under it, as Files' bar shows them. At accessibility sizes the words would crowd four
    /// buttons off the bar, so the icon stays and VoiceOver reads the words.
    private func barLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.title3)
            if !dynamicTypeSize.isAccessibilitySize {
                Text(title.replacingOccurrences(of: "…", with: ""))
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Everything Select does once an action is picked (#4720), shared by the Library and a collection's screen: the bar at
/// the bottom, the Photos-style confirmation before Move to Recently Deleted, the Add to Collection sheet, and the call
/// into the model. `done` ends Select after an action, as Mail and Photos do.
struct LibrarySelectActions: ViewModifier {
    @EnvironmentObject private var model: Gate1AppModel
    let isSelecting: Bool
    /// The ticked items, in the view's order.
    let selectedRows: [LibraryItemRow]
    /// The collection whose screen this is; nil in the Library.
    let collection: ItemCollection?
    let done: () -> Void

    @State private var confirmsDelete = false
    @State private var addsToCollection = false

    private var ids: [String] { selectedRows.map(\.id) }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting {
                    LibrarySelectActionBar(
                        available: LibraryBulkAction.available(for: selectedRows, insideCollection: collection != nil),
                        insideCollection: collection != nil, perform: perform)
                }
            }
            .confirmationDialog(
                LibraryBulkAction.deleteConfirmation(count: selectedRows.count).title,
                isPresented: $confirmsDelete, titleVisibility: .visible
            ) {
                Button(LibraryBulkAction.deleteConfirmation(count: selectedRows.count).button, role: .destructive) {
                    model.moveItemsToTrash(ids)
                    done()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(LibraryBulkAction.deleteConfirmation(count: selectedRows.count).message)
            }
            .trackedSheet(isPresented: $addsToCollection) {
                LibraryAddToCollectionSheet(itemIDs: ids, excludingCollectionID: collection?.id) { done() }
                    .environmentObject(model)
            }
    }

    private func perform(_ action: LibraryBulkAction) {
        let ids = ids
        switch action {
        case .addToQueue:
            model.addItemsToQueue(ids)
            done()
        case .addToCollection:
            addsToCollection = true
        case .markFinished:
            model.markItemsFinished(ids)
            done()
        case .markUnfinished:
            model.markItemsUnfinished(ids)
            done()
        case .removeFromCollection:
            guard let collection else { return }
            Task { await model.removeItems(ids, fromCollection: collection) }
            done()
        case .moveToRecentlyDeleted:
            confirmsDelete = true
        }
    }
}

extension View {
    func librarySelectActions(
        isSelecting: Bool, selectedRows: [LibraryItemRow], collection: ItemCollection? = nil, done: @escaping () -> Void
    ) -> some View {
        modifier(LibrarySelectActions(isSelecting: isSelecting, selectedRows: selectedRows, collection: collection, done: done))
    }
}
