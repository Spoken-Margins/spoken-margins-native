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

    /// Saves one change through `LibraryCollectionModel`, whose writes read the stored collection on its serial writer,
    /// so a tick or rename made while an import fills the collection never writes back this sheet's older copy (#3769).
    /// Then reloads so the sheet and the Margins scope show what is stored. `needsName` and `nameTaken` are the lines
    /// for a name that is empty or already used.
    private func commit(
        needsName: String = ItemCollectionEditing.Wording.renameRefused,
        nameTaken: String = ItemCollectionEditing.Wording.renameRefused,
        fileID: String = #fileID, line: Int = #line,
        _ change: @escaping (LibraryCollectionModel, SQLiteSessionStore) async -> LibraryCollectionModel.Outcome,
        onSaved: @escaping () -> Void = {}
    ) {
        guard let store = model.store else {
            model.reportFailure("The Library isn't ready yet.", fileID: fileID, line: line)
            return
        }
        let collections = model.libraryCollections
        Task {
            let outcome = await change(collections, store)
            switch outcome {
            case .saved:
                problem = nil
                onSaved()
            case .needsName:
                problem = needsName
            case .nameTaken:
                problem = nameTaken
            case .failed(let error):
                model.reportFailure(error, context: "Collection change failed", fileID: fileID, line: line)
            }
            load()
        }
    }

    private func toggle(_ collection: ItemCollection) {
        // What the tick means on the row as drawn: in when it showed no checkmark.
        let included = !collection.itemIDs.contains(item.id)
        let itemID = item.id
        commit { collections, store in
            await collections.setMembership(of: itemID, included: included, in: collection, store: store)
        }
    }

    private func create() {
        let name = newName
        let itemID = item.id
        commit(needsName: ItemCollectionEditing.Wording.nameRequired, nameTaken: ItemCollectionEditing.Wording.nameTaken, { collections, store in
            await collections.create(name: name, itemIDs: [itemID], store: store, selects: false)
        }, onSaved: { newName = "" })
    }

    private func beginRename(_ collection: ItemCollection) {
        renameText = collection.name
        renaming = collection
    }

    private func commitRename() {
        guard let collection = renaming else { return }
        renaming = nil
        let name = renameText
        // Renames the stored copy, so items an import added since the sheet opened stay in it (#3769).
        commit { collections, store in await collections.rename(collection, to: name, store: store) }
    }

    private func delete(_ collection: ItemCollection) {
        commit { collections, store in await collections.delete(collection, store: store) }
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
