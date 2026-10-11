import SwiftUI
import SessionKit
import SessionKitPersistence

/// "Add to Collection…" for a Library item (#490): tick the collections the item belongs to, make a new one on
/// the spot, rename or delete one. A collection only lists items, so deleting it never touches items or Margins.
struct ItemCollectionSheet: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss

    let item: LibraryItemRow

    @State private var collections: [ItemCollection] = []
    @State private var newName = ""
    @State private var renaming: ItemCollection?
    @State private var renameText = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if collections.isEmpty {
                        Text("No collections yet. Make one below.")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    ForEach(collections) { collection in
                        Button { toggle(collection) } label: {
                            HStack {
                                Text(collection.name).foregroundStyle(AppColors.text)
                                Spacer()
                                if collection.itemIDs.contains(item.id) {
                                    Image(systemName: "checkmark").foregroundStyle(AppColors.ochre)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(collection.itemIDs.contains(item.id) ? .isSelected : [])
                        .accessibilityIdentifier("collection.row.\(collection.id)")
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { beginRename(collection) }
                            Button("Delete Collection", systemImage: "trash", role: .destructive) { delete(collection) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { delete(collection) }
                            Button("Rename") { beginRename(collection) }.tint(AppColors.ochre)
                        }
                    }
                } header: {
                    Text(item.title)
                } footer: {
                    Text("Deleting a collection keeps its items and their Margins.")
                }
                Section("New Collection") {
                    TextField("Name, such as HIST 210", text: $newName)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("collection.new.field")
                    Button("Add Collection and This Item", systemImage: "plus.circle", action: create)
                        .disabled(ItemCollectionEditing.normalizedName(newName) == nil)
                        .accessibilityIdentifier("collection.new.button")
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(AppColors.secondaryText) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { load() }
            .alert("Rename Collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename", action: commitRename)
            }
        }
        .accessibilityIdentifier("collection.sheet")
    }

    private func load() {
        collections = (try? model.store?.loadItemCollections()) ?? []
        model.marginCollectionQuery.refreshCollection(from: collections)
    }

    /// Saves one change, then reloads so the sheet and the Margins scope show what is stored.
    private func commit(_ change: (SQLiteSessionStore) throws -> Void) {
        guard let store = model.store else { return model.reportFailure("The Library isn't ready yet.") }
        do {
            try change(store)
            problem = nil
        } catch {
            model.reportFailure(error, context: "Collection change failed")
        }
        load()
    }

    private func toggle(_ collection: ItemCollection) {
        commit { try $0.saveItemCollection(ItemCollectionEditing.toggling(itemID: item.id, in: collection, now: Date())) }
    }

    private func create() {
        guard let created = ItemCollectionEditing.creating(
            name: newName, itemID: item.id, id: "collection-\(UUID().uuidString)", now: Date(), in: collections
        ) else {
            problem = ItemCollectionEditing.normalizedName(newName) == nil
                ? "Type a name for the collection."
                : "You already have a collection with that name."
            return
        }
        commit { try $0.saveItemCollection(created) }
        newName = ""
    }

    private func beginRename(_ collection: ItemCollection) {
        renameText = collection.name
        renaming = collection
    }

    private func commitRename() {
        guard let collection = renaming else { return }
        renaming = nil
        guard let renamed = ItemCollectionEditing.renaming(collection, to: renameText, now: Date(), in: collections) else {
            problem = "That name is empty or already used by another collection."
            return
        }
        commit { try $0.saveItemCollection(renamed) }
    }

    private func delete(_ collection: ItemCollection) {
        commit { try $0.deleteItemCollection(id: collection.id) }
    }
}
