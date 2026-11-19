import SwiftUI
import SessionKit

/// Where a collection row leads in the Library's navigation (#3769).
struct LibraryCollectionRoute: Hashable, Identifiable {
    let id: String
}

/// A collection's own screen (#3769, owner's decision 2026-11-19): its items in order, each with its state in words and
/// a shape; Play All from the first unfinished item with the rest queued; a tap on an item plays from that item; Add to
/// Queue; Export Margins; Rename; Delete Collection, which keeps every item; and Select with Remove from Collection.
struct LibraryCollectionScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let collectionID: String

    @State private var pendingNewMarginsOffer: NewMarginsOfferRequest?
    @State private var renaming: ItemCollection?
    @State private var renameText = ""
    @State private var problem: String?
    @State private var confirmsDelete = false
    @State private var isSelecting = false
    @State private var selection = LibrarySelection()

    /// The collection as the Library has it now; nil once it is deleted.
    private var row: LibraryCollectionRow? {
        model.libraryCollectionRows.first { $0.collectionID == collectionID }
    }

    private var collection: ItemCollection? {
        model.libraryCollections.collections.first { $0.id == collectionID }
    }

    private var entryIDs: [String] { row?.progress.itemIDs ?? [] }

    var body: some View {
        List {
            if let row {
                header(row)
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
                if row.progress.entries.isEmpty {
                    Text(row.progress.isImporting ? row.progress.detailLine : "Nothing here yet. In the Library, tap Select, tick what belongs here, then Add to Collection.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                }
                ForEach(row.progress.entries) { entry in
                    entryRow(entry, total: row.progress.itemCount, row: row)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 0)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.bone)
        .navigationTitle(isSelecting ? selection.title : (row?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSelecting)
        .toolbar { toolbarContent }
        .librarySelectActions(
            isSelecting: isSelecting,
            selectedRows: selectedRows,
            collection: collection,
            done: endSelecting)
        .collectionRenameAlert(collection: $renaming, text: $renameText, commit: commitRename)
        .confirmationDialog(
            "Delete “\(row?.name ?? "")”?", isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button("Delete Collection", role: .destructive) {
                Task { if await model.deleteCollection(collectionID: collectionID) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ItemCollectionEditing.Wording.deleteKeepsEverything)
        }
        .newMarginsOffer($pendingNewMarginsOffer)
        .onChange(of: entryIDs) { _, ids in selection.keepOnly(ids) }
        .accessibilityIdentifier("library.collection.screen")
    }

    private var selectedRows: [LibraryItemRow] {
        guard let row else { return [] }
        let ordered = selection.ordered(in: entryIDs)
        let rows = Dictionary(row.progress.entries.map { ($0.itemID, $0.row) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { rows[$0] }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.selectAllTitle(visible: entryIDs)) { selection.toggleAll(entryIDs) }
                    .disabled(entryIDs.isEmpty)
                    .accessibilityIdentifier("library.collection.selectAll")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: endSelecting)
                    .accessibilityIdentifier("library.collection.selectDone")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { isSelecting = true }
                    .disabled(entryIDs.isEmpty)
                    .accessibilityIdentifier("library.collection.select")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Export Margins…", systemImage: "square.and.arrow.up") {
                        model.exportCollectionMargins(collectionID: collectionID)
                    }
                    Button("Rename…", systemImage: "pencil", action: beginRename)
                    Button("Delete Collection…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("library.collection.more")
            }
        }
    }

    /// The count line, then Play All (Continue / Play Again) and Add to Queue, side by side when they fit.
    private func header(_ row: LibraryCollectionRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if row.progress.isImporting { ProgressView().controlSize(.mini) }
                Text(row.progress.detailLine)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("library.collection.problem")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { headerButtons(row) }
                VStack(alignment: .leading, spacing: 8) { headerButtons(row) }
            }
            .disabled(isSelecting)
        }
    }

    @ViewBuilder private func headerButtons(_ row: LibraryCollectionRow) -> some View {
        Button {
            if let plan = row.playPlan { model.playCollection(plan, name: row.name) { pendingNewMarginsOffer = $0 } }
        } label: {
            Label(row.playPlan?.label.rawValue ?? LibraryCollectionPlayPlan.Label.start.rawValue,
                  systemImage: row.playPlan?.label == .playAgain ? "arrow.counterclockwise" : "play.fill")
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(row.playPlan == nil)
        .accessibilityLabel(row.playPlan?.label.accessibilityLabel(name: row.name) ?? "Play all of \(row.name)")
        .accessibilityIdentifier("library.collection.playAll")
        Button {
            model.queueCollection(row.progress)
        } label: {
            Label(LibraryBulkAction.addToQueue.title, systemImage: LibraryBulkAction.addToQueue.symbol)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!row.progress.canPlay)
        .accessibilityIdentifier("library.collection.addToQueue")
    }

    @ViewBuilder
    private func entryRow(_ entry: LibraryCollectionProgress.Entry, total: Int, row: LibraryCollectionRow) -> some View {
        if isSelecting {
            LibrarySelectableRow(
                isSelected: selection.contains(entry.itemID),
                label: entry.accessibilityLabel(of: total),
                toggle: { selection.toggle(entry.itemID) }
            ) { entryContent(entry) }
        } else {
            Button {
                if let plan = LibraryCollectionPlayPlan.playFrom(itemID: entry.itemID, row.progress) {
                    model.playCollection(plan, name: row.name) { pendingNewMarginsOffer = $0 }
                }
            } label: {
                entryContent(entry)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.accessibilityLabel(of: total))
            .accessibilityHint("Plays from here.")
            .accessibilityIdentifier("library.collection.entry.\(entry.itemID)")
            .contextMenu {
                Button("Play from Here", systemImage: "play") {
                    if let plan = LibraryCollectionPlayPlan.playFrom(itemID: entry.itemID, row.progress) {
                        model.playCollection(plan, name: row.name) { pendingNewMarginsOffer = $0 }
                    }
                }
                if entry.row.spokenNoteId == nil {
                    Button("Open", systemImage: "arrow.right") { model.openItemFromTap(id: entry.itemID) }
                }
            }
            .accessibilityActions {
                if entry.row.spokenNoteId == nil {
                    Button("Open") { model.openItemFromTap(id: entry.itemID) }
                }
            }
        }
    }

    /// The item's place, its state in words beside a shape (never colour alone), and its title.
    private func entryContent(_ entry: LibraryCollectionProgress.Entry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: entry.state.symbol)
                .font(.title3)
                .foregroundStyle(AppColors.evergreen)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.row.title)
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text("\(entry.number) · \(entry.state.word)")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func endSelecting() {
        isSelecting = false
        selection.deselectAll()
    }

    private func beginRename() {
        guard let collection else { return }
        renameText = collection.name
        renaming = collection
    }

    private func commitRename() {
        guard renaming != nil else { return }
        renaming = nil
        let name = renameText
        Task { problem = await model.renameCollection(collectionID: collectionID, to: name) }
    }
}
