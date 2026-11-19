import Combine
import SwiftUI
import SessionKit
import SessionKitPersistence

/// The Library's collection chips (#4343, PR 2): the collections the listener has, which one the Library is narrowed
/// to, and the saves behind the New collection sheet and a chip's long-press. Kept out of `Gate1AppModel`; the model
/// owns one of these and reads `selection` where it filters the Library.
///
/// The collections arrive with every Library read (`LibraryReadSnapshot.collections`), so the chip row draws with the
/// rows and does not snap in after them. The selection is never saved: every launch opens on All, so nobody finds a
/// Library that seems to be missing items.
@MainActor
final class LibraryCollectionModel: ObservableObject {
    @Published private(set) var collections: [ItemCollection] = []
    /// The collection the Library is narrowed to; nil is All.
    @Published private(set) var selection: ItemCollectionScope?
    /// What each imported folder or link list remembers (#3769), keyed by its collection's ID; read with the Library.
    @Published private(set) var folders: [LibraryFolderRecord] = []
    /// Set while a folder or link list is being imported as a collection, so the importers it calls report to it
    /// instead of putting up a banner per file (#3769).
    var importCapture: CollectionImportCapture?
    private var willChangeRelay: AnyCancellable?
    /// Called when this model's own save or delete changed the collections, so a Library read that began before it is
    /// seen as stale and read again, never published over what was just saved.
    var onLocalWrite: (() -> Void)?

    /// Sends `target` a change notification whenever the collections or the selection are about to change, so the
    /// model's views, which filter the Library by the selection, redraw (the Quick Folder's pattern, #981).
    func forwardWillChange(to target: ObservableObjectPublisher) {
        willChangeRelay = objectWillChange.sink { _ in target.send() }
    }

    enum Outcome {
        case saved
        case needsName
        case nameTaken
        case failed(Error)
    }

    /// The collections as the store has them after a Library read or a save. A selected collection that is gone falls
    /// back to All; one that changed keeps its place with its current members.
    func publish(_ stored: [ItemCollection], folders storedFolders: [LibraryFolderRecord]? = nil) {
        if stored != collections { collections = stored }
        if let storedFolders, storedFolders != folders { folders = storedFolders }
        let next = LibraryCollectionScope.selection(selection, afterCollectionsChanged: stored)
        if next != selection { selection = next }
    }

    /// A chip tap: nil is All.
    func select(collectionID: String?) {
        let next = LibraryCollectionScope.selection(collectionID: collectionID, in: collections)
        if next != selection { selection = next }
    }

    /// Makes a collection holding `itemIDs` and selects it, so the Library shows what was just made.
    func create(name: String, itemIDs: [String], store: SQLiteSessionStore, now: Date = Date()) async -> Outcome {
        guard ItemCollectionEditing.normalizedName(name) != nil else { return .needsName }
        guard let created = ItemCollectionEditing.creating(
            name: name, itemIDs: itemIDs, id: "collection-\(UUID().uuidString)", now: now, in: collections
        ) else { return .nameTaken }
        if let failure = await save(created, store: store) { return .failed(failure) }
        select(collectionID: created.id)
        return .saved
    }

    /// Edit Items: the collection holds exactly the ticked items, among the ones the checklist offered.
    func setItems(
        _ chosen: Set<String>, in collection: ItemCollection, choosable: [String], store: SQLiteSessionStore, now: Date = Date()
    ) async -> Outcome {
        let edited = ItemCollectionEditing.settingItems(chosen, in: collection, choosable: choosable, now: now)
        if let failure = await save(edited, store: store) { return .failed(failure) }
        return .saved
    }

    func rename(_ collection: ItemCollection, to name: String, store: SQLiteSessionStore, now: Date = Date()) async -> Outcome {
        guard ItemCollectionEditing.normalizedName(name) != nil else { return .needsName }
        guard let renamed = ItemCollectionEditing.renaming(collection, to: name, now: now, in: collections) else { return .nameTaken }
        if let failure = await save(renamed, store: store) { return .failed(failure) }
        return .saved
    }

    func delete(_ collection: ItemCollection, store: SQLiteSessionStore) async -> Outcome {
        let result = await Self.offMain { () -> Result<[ItemCollection]?, Error> in
            do { try store.deleteItemCollection(id: collection.id) } catch { return .failure(error) }
            return .success(try? store.loadItemCollections())
        }
        switch result {
        case .failure(let error): return .failed(error)
        case .success(let stored):
            onLocalWrite?()
            publish(stored ?? collections.filter { $0.id != collection.id })
            return .saved
        }
    }

    /// An import's collection and record (#3769): the collection first, then the record, so an interruption between the
    /// two leaves an ordinary collection (`LibraryFolderRecord`'s write order). Saved before the first file and after each.
    func saveImport(_ collection: ItemCollection, record: LibraryFolderRecord, store: SQLiteSessionStore) async -> Error? {
        let result = await Self.offMain { () -> Result<([ItemCollection]?, [LibraryFolderRecord]?), Error> in
            do {
                try store.saveItemCollection(collection)
                try store.saveLibraryFolder(record)
            } catch { return .failure(error) }
            return .success((try? store.loadItemCollections(), try? store.loadLibraryFolders()))
        }
        switch result {
        case .failure(let error):
            return error
        case .success(let (stored, storedFolders)):
            var local = collections
            if let index = local.firstIndex(where: { $0.id == collection.id }) { local[index] = collection } else { local.append(collection) }
            var localFolders = folders
            if let index = localFolders.firstIndex(where: { $0.id == record.id }) { localFolders[index] = record } else { localFolders.append(record) }
            onLocalWrite?()
            publish(stored ?? local, folders: storedFolders ?? localFolders)
            return nil
        }
    }

    /// Saves, then reloads so the chips show what is stored. Returns the error when the save failed. A failed read after
    /// a good save keeps what the save just wrote, so the chips never lose it to a blip.
    private func save(_ collection: ItemCollection, store: SQLiteSessionStore) async -> Error? {
        let result = await Self.offMain { () -> Result<[ItemCollection]?, Error> in
            do { try store.saveItemCollection(collection) } catch { return .failure(error) }
            return .success(try? store.loadItemCollections())
        }
        switch result {
        case .failure(let error):
            return error
        case .success(let stored):
            var local = collections
            if let index = local.firstIndex(where: { $0.id == collection.id }) { local[index] = collection } else { local.append(collection) }
            onLocalWrite?()
            publish(stored ?? local)
            return nil
        }
    }

    /// The store is synchronous; its work runs off the main actor and the result comes back here (#2256).
    private static func offMain<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}
