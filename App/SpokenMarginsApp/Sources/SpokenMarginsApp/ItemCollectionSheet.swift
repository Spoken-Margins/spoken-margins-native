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
                                    Image(systemName: "checkmark").foregroundStyle(AppColors.ochreText)
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
                        // The same actions for VoiceOver and Switch Control, which can't long-press (#1917, #3730).
                        .accessibilityActions {
                            Button("Rename") { beginRename(collection) }
                            Button("Delete Collection") { delete(collection) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { delete(collection) }
                            Button("Rename") { beginRename(collection) }.tint(AppColors.swipeOchre)
                        }
                    }
                } header: {
                    Text(item.title)
                } footer: {
                    Text(ItemCollectionEditing.Wording.deleteKeepsEverything)
                }
                Section("New Collection") {
                    AppTextField("Name, such as HIST 210", text: $newName)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("collection.new.field")
                    Button("Create Collection and Add This", systemImage: "plus.circle", action: create)
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
            .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("collection.done.button") }
            .task { load() }
            .collectionRenameAlert(collection: $renaming, text: $renameText, commit: commitRename)
        }
        .accessibilityIdentifier("collection.sheet")
    }

    private func load() {
        // A failed read keeps what is shown, so an active Margins scope isn't dropped by a blip.
        guard let stored = try? model.store?.loadItemCollections() else { return }
        collections = stored
        model.marginCollectionQuery.refreshCollection(from: stored)
        model.libraryCollections.publish(stored) // the Library's chip row follows a long-press change (#4343)
    }

    /// Saves one change, then reloads so the sheet and the Margins scope show what is stored.
    @discardableResult
    private func commit(fileID: String = #fileID, line: Int = #line, _ change: (SQLiteSessionStore) throws -> Void) -> Bool {
        guard let store = model.store else {
            model.reportFailure("The Library isn't ready yet.", fileID: fileID, line: line)
            return false
        }
        defer { load() }
        do {
            try change(store)
            problem = nil
            return true
        } catch {
            model.reportFailure(error, context: "Collection change failed", fileID: fileID, line: line)
            return false
        }
    }

    private func toggle(_ collection: ItemCollection) {
        commit { try $0.saveItemCollection(ItemCollectionEditing.toggling(itemID: item.id, in: collection, now: Date())) }
    }

    private func create() {
        guard let created = ItemCollectionEditing.creating(
            name: newName, itemID: item.id, id: "collection-\(UUID().uuidString)", now: Date(), in: collections
        ) else {
            problem = ItemCollectionEditing.normalizedName(newName) == nil
                ? ItemCollectionEditing.Wording.nameRequired
                : ItemCollectionEditing.Wording.nameTaken
            return
        }
        if commit({ try $0.saveItemCollection(created) }) { newName = "" }
    }

    private func beginRename(_ collection: ItemCollection) {
        renameText = collection.name
        renaming = collection
    }

    private func commitRename() {
        guard let collection = renaming else { return }
        renaming = nil
        guard let renamed = ItemCollectionEditing.renaming(collection, to: renameText, now: Date(), in: collections) else {
            problem = ItemCollectionEditing.Wording.renameRefused
            return
        }
        commit { try $0.saveItemCollection(renamed) }
    }

    private func delete(_ collection: ItemCollection) {
        commit { try $0.deleteItemCollection(id: collection.id) }
    }
}

extension View {
    /// The "Rename Collection" alert, shared by the Add to Collection sheet and the Library's collection chips (#4343), so
    /// the two never differ. The alert's text field is the system's own, so it keeps a plain `TextField` (the placeholder
    /// colour guard allows one in this file). `commit` reads the collection and the text, and clears the collection.
    func collectionRenameAlert(collection: Binding<ItemCollection?>, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        alert("Rename Collection", isPresented: Binding(get: { collection.wrappedValue != nil }, set: { if !$0 { collection.wrappedValue = nil } })) {
            TextField("Name", text: text)
            Button("Cancel", role: .cancel) { collection.wrappedValue = nil }
            Button("Rename", action: commit)
        }
    }
}
