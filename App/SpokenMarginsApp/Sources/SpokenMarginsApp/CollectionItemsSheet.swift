import SwiftUI
import SessionKit
import SessionKitPersistence

/// **New collection** and **Edit Items** (#4343, PR 2): one sheet that names a collection and ticks the Library items in
/// it, the way Photos makes a new album, so a semester's readings go in at once instead of one long-press each. Edit
/// Items is the same checklist for a collection that exists; it has no name field.
///
/// Items the checklist cannot show (the ones in Recently Deleted) stay in a collection when it is edited, so restoring an
/// item brings it back into its collection.
struct CollectionItemsSheet: View {
    enum Mode: Identifiable {
        case create
        case edit(ItemCollection)

        var id: String {
            switch self {
            case .create: return "new"
            case .edit(let collection): return "edit-\(collection.id)"
            }
        }
    }

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var name = ""
    @State private var search = ""
    @State private var chosen: Set<String>
    /// The checklist's rows for the current search; recomputed when the search or the Library changes, not on every tick.
    @State private var rows: [LibraryItemRow] = []
    /// False until the first checklist is built, so a Library with items never shows "No items match." for a frame.
    @State private var rowsLoaded = false
    @State private var problem: String?
    /// Set the moment Create is tapped, so a second tap before the sheet closes makes no second collection.
    @State private var isSaving = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create: _chosen = State(initialValue: [])
        case .edit(let collection): _chosen = State(initialValue: Set(collection.itemIDs))
        }
    }

    private var isCreating: Bool { if case .create = mode { return true } else { return false } }

    private var title: String {
        switch mode {
        case .create: return "New collection"
        case .edit(let collection): return collection.name
        }
    }

    private var canCommit: Bool {
        !isSaving && (!isCreating || ItemCollectionEditing.normalizedName(name) != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                if isCreating {
                    Section {
                        AppTextField("Name, such as HIST 210", text: $name)
                            .submitLabel(.done)
                            .accessibilityIdentifier("collection.items.name")
                    }
                }
                Section {
                    AppSearchField("Search title, source, or author", text: $search, identifier: "collection.items.search")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    if model.libraryItems.isEmpty {
                        Text("Your Library has no items yet.").foregroundStyle(AppColors.secondaryText)
                    } else if rowsLoaded, rows.isEmpty {
                        Text("No items match.").foregroundStyle(AppColors.secondaryText)
                    }
                    ForEach(rows) { row in itemRow(row) }
                } header: {
                    // A header, not a row, so the count stays readable while the list scrolls.
                    Text(chosenCountLine).accessibilityIdentifier("collection.items.count")
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(AppColors.secondaryText) }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively) // the search box's keyboard goes down on a drag (#4636)
            .background(AppColors.bone)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("collection.items.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Create" : "Done", action: commit)
                        .disabled(!canCommit)
                        .accessibilityIdentifier("collection.items.commit")
                }
            }
            .task { refreshRows() }
            .onChange(of: search) { _, _ in refreshRows() }
            .onChange(of: model.libraryItems.map(\.id)) { _, _ in refreshRows() }
        }
        .accessibilityIdentifier("collection.items.sheet")
    }

    private var chosenCountLine: String {
        let count = isCreating ? chosen.count : chosen.intersection(Set(model.libraryItems.map(\.id))).count
        return "\(count) chosen"
    }

    private func itemRow(_ row: LibraryItemRow) -> some View {
        let isChosen = chosen.contains(row.id)
        return Button { toggle(row.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: row.mediaSymbol)
                    .foregroundStyle(AppColors.evergreen)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).foregroundStyle(AppColors.text).multilineTextAlignment(.leading)
                    Text(kindLine(row)).font(.caption).foregroundStyle(AppColors.secondaryText)
                }
                Spacer(minLength: 8)
                // A checkmark, not a colour, says which items are in.
                if isChosen { Image(systemName: "checkmark").foregroundStyle(AppColors.ochreText).accessibilityHidden(true) }
            }
            .frame(minHeight: TapTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("collection.items.row.\(row.id)")
    }

    private func kindLine(_ row: LibraryItemRow) -> String {
        LibraryRowWording.kindLabel(
            mediaType: row.mediaType, sourceReference: row.sourceReference,
            sourceReferenceType: row.sourceReferenceType, usesNewReader: row.usesNewReader)
    }

    private func refreshRows() {
        rows = LibraryCollectionScope.checklistRows(model.libraryItems, search: search)
        rowsLoaded = true
    }

    private func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    private func commit() {
        guard !isSaving else { return }
        guard let store = model.store else {
            model.reportFailure("The Library isn't ready yet.")
            problem = ItemCollectionEditing.Wording.saveFailed
            return
        }
        isSaving = true // before the save starts, so a second tap on Create finds the sheet busy
        let libraryOrder = model.libraryItems.map(\.id)
        let chosenNow = chosen
        let nameNow = name
        let mode = mode
        Task {
            let outcome: LibraryCollectionModel.Outcome
            switch mode {
            case .create:
                outcome = await model.libraryCollections.create(
                    name: nameNow, itemIDs: libraryOrder.filter(chosenNow.contains), store: store)
            case .edit(let opened):
                // The collection as it is now: another sheet may have changed it while this one was open.
                guard let current = model.libraryCollections.collections.first(where: { $0.id == opened.id }) else {
                    dismiss()
                    return
                }
                outcome = await model.libraryCollections.setItems(chosenNow, in: current, choosable: libraryOrder, store: store)
            }
            finish(outcome)
        }
    }

    private func finish(_ outcome: LibraryCollectionModel.Outcome) {
        switch outcome {
        case .saved:
            model.marginCollectionQuery.refreshCollection(from: model.libraryCollections.collections)
            dismiss()
        case .needsName:
            problem = ItemCollectionEditing.Wording.nameRequired
            isSaving = false
        case .nameTaken:
            problem = ItemCollectionEditing.Wording.nameTaken
            isSaving = false
        case .failed(let error):
            model.reportFailure(error, context: "Collection change failed")
            problem = ItemCollectionEditing.Wording.saveFailed
            isSaving = false
        }
    }
}
