import Combine
import SwiftUI
import SessionKit
import SessionKitPersistence

/// The Library's collections (#4343, #3769): the collections the listener has, the Library's Collections | All Items
/// choice, and the saves behind the collection screen and Select's Add to Collection (#4720). Kept out of
/// `Gate1AppModel`; the model owns one of these.
///
/// The collections arrive with every Library read (`LibraryReadSnapshot.collections`), so collection rows draw with the
/// item rows and do not snap in after them.
@MainActor
final class LibraryCollectionModel: ObservableObject {
    @Published private(set) var collections: [ItemCollection] = []
    /// Collections | All Items (#3769), kept between launches.
    @Published var viewMode: LibraryViewMode = LibraryViewMode.load(defaults: .standard) {
        didSet { if viewMode != oldValue { viewMode.save(defaults: .standard) } }
    }
    /// What each imported folder or link list remembers (#3769), keyed by its collection's ID; read with the Library.
    @Published private(set) var folders: [LibraryFolderRecord] = []
    /// Set while a folder or link list is being imported as a collection, so the importers it calls report to it
    /// instead of putting up a banner per file (#3769).
    var importCapture: CollectionImportCapture?
    private var willChangeRelay: AnyCancellable?
    /// Called when this model's own save or delete changed the collections, so a Library read that began before it is
    /// seen as stale and read again, never published over what was just saved.
    var onLocalWrite: (() -> Void)?

    /// Sends `target` a change notification whenever the collections or the view choice are about to change, so the
    /// model's views redraw (the Quick Folder's pattern, #981).
    func forwardWillChange(to target: ObservableObjectPublisher) {
        willChangeRelay = objectWillChange.sink { _ in target.send() }
    }

    enum Outcome {
        case saved
        case needsName
        case nameTaken
        case failed(Error)
    }

    /// The collections as the store has them after a Library read or a save.
    func publish(_ stored: [ItemCollection], folders storedFolders: [LibraryFolderRecord]? = nil) {
        if stored != collections { collections = stored }
        if let storedFolders, storedFolders != folders { folders = storedFolders }
    }

    /// Makes a collection holding `itemIDs`, in that order (Select's Add to Collection, a new name typed inline).
    func create(name: String, itemIDs: [String], store: SQLiteSessionStore, now: Date = Date()) async -> Outcome {
        guard ItemCollectionEditing.normalizedName(name) != nil else { return .needsName }
        guard let created = LibraryCollectionAdding.creating(
            name: name, with: itemIDs, id: "collection-\(UUID().uuidString)", now: now, in: collections
        ) else { return .nameTaken }
        if let failure = await save(created.collection, store: store) { return .failed(failure) }
        return .saved
    }

    /// Select's Add to Collection on an existing collection (#4720): the items join at the end in the order given.
    /// Returns how many were new to it, or the failure.
    func add(_ itemIDs: [String], toCollectionID id: String, store: SQLiteSessionStore, now: Date = Date()) async -> Result<Int, Error> {
        guard let current = collections.first(where: { $0.id == id }) else { return .success(0) }
        let outcome = LibraryCollectionAdding.adding(itemIDs, to: current, now: now)
        guard outcome.added > 0 else { return .success(0) }
        if let failure = await save(outcome.collection, store: store) { return .failure(failure) }
        return .success(outcome.added)
    }

    /// Remove from Collection (#4720): the items leave this collection and stay in the Library with their Margins.
    func remove(_ itemIDs: [String], fromCollectionID id: String, store: SQLiteSessionStore, now: Date = Date()) async -> Result<Int, Error> {
        guard let current = collections.first(where: { $0.id == id }) else { return .success(0) }
        let edited = LibraryCollectionAdding.removing(itemIDs, from: current, now: now)
        guard edited.removed > 0 else { return .success(0) }
        if let failure = await save(edited.collection, store: store) { return .failure(failure) }
        return .success(edited.removed)
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

    /// Saves, then reloads so the Library shows what is stored. Returns the error when the save failed. A failed read after
    /// a good save keeps what the save just wrote, so the Library never loses it to a blip.
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
