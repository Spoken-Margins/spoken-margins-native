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

    /// Makes a collection holding `itemIDs`, in that order (Select's Add to Collection, a new name typed inline). `id`
    /// is the new collection's, for a caller that keeps a link to it (the sender offer, #5033).
    func create(
        name: String, itemIDs: [String], store: SQLiteSessionStore, id: String = "collection-\(UUID().uuidString)", now: Date = Date()
    ) async -> Outcome {
        guard ItemCollectionEditing.normalizedName(name) != nil else { return .needsName }
        guard let created = LibraryCollectionAdding.creating(
            name: name, with: itemIDs, id: id, now: now, in: collections
        ) else { return .nameTaken }
        if let failure = await save(created.collection, store: store) { return .failed(failure) }
        return .saved
    }

    /// Select's Add to Collection on an existing collection (#4720): the items join at the end in the order given.
    /// Returns how many were new to it, or the failure. Adds to the stored copy, so an import filling it keeps its items.
    func add(_ itemIDs: [String], toCollectionID id: String, store: SQLiteSessionStore, now: Date = Date()) async -> Result<Int, Error> {
        let result = await update(id, store: store) { current, _ in LibraryCollectionAdding.adding(itemIDs, to: current, now: now).collection }
        switch result {
        case .saved(_, let was): return .success(LibraryCollectionAdding.adding(itemIDs, to: was, now: now).added)
        case .gone, .refused: return .success(0)
        case .failed(let error): return .failure(error)
        }
    }

    /// Remove from Collection (#4720): the items leave this collection and stay in the Library with their Margins.
    func remove(_ itemIDs: [String], fromCollectionID id: String, store: SQLiteSessionStore, now: Date = Date()) async -> Result<Int, Error> {
        let result = await update(id, store: store) { current, _ in LibraryCollectionAdding.removing(itemIDs, from: current, now: now).collection }
        switch result {
        case .saved(_, let was): return .success(LibraryCollectionAdding.removing(itemIDs, from: was, now: now).removed)
        case .gone, .refused: return .success(0)
        case .failed(let error): return .failure(error)
        }
    }

    /// The per-item Add to Collection sheet's tick: puts `itemID` in the stored collection or takes it out. `included` is
    /// what the tick means on the row the sheet drew; it lands on the stored copy, so items an import added since stay (#3769).
    func setMembership(
        of itemID: String, included: Bool, in collection: ItemCollection, store: SQLiteSessionStore, now: Date = Date()
    ) async -> Outcome {
        await update(collection.id, store: store) { current, _ in
            ItemCollectionEditing.setting(itemID: itemID, included: included, in: current, now: now)
        }.outcome
    }

    func rename(_ collection: ItemCollection, to name: String, store: SQLiteSessionStore, now: Date = Date()) async -> Outcome {
        guard ItemCollectionEditing.normalizedName(name) != nil else { return .needsName }
        // Renames the stored copy, so items an import added since the row was drawn stay in it (#3769).
        let result = await update(collection.id, store: store) { current, all in
            ItemCollectionEditing.renaming(current, to: name, now: now, in: all)
        }
        if case .refused = result { return .nameTaken }
        return result.outcome
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

    /// What `update` did.
    enum Update {
        /// Saved; the collection as it is now stored, and the stored copy it replaced (for counting what changed).
        case saved(ItemCollection, was: ItemCollection)
        /// The collection is no longer stored: deleted since the caller last looked.
        case gone
        /// The change declined (a name already taken); nothing was written.
        case refused
        case failed(Error)

        var outcome: Outcome {
            switch self {
            case .saved, .gone: return .saved
            case .refused: return .nameTaken
            case .failed(let error): return .failed(error)
            }
        }
    }

    /// Changes one collection as the store has it now, never a copy read earlier (#3769). The read, the change and the
    /// write run on one serial writer, so an import filling a collection and the listener renaming, editing or deleting
    /// it can't undo each other's work, and a deleted collection is never saved back. `change` gets the stored
    /// collection and every stored collection (for name checks) and returns the new one, or nil to decline. `record`,
    /// when given, is saved after the collection (`LibraryFolderRecord`'s write order) only when the collection was.
    func update(
        _ id: String, record: LibraryFolderRecord? = nil, store: SQLiteSessionStore,
        _ change: @escaping @Sendable (ItemCollection, [ItemCollection]) -> ItemCollection?
    ) async -> Update {
        enum Written: Sendable { case saved(ItemCollection, ItemCollection, [ItemCollection]?, [LibraryFolderRecord]?), gone, refused, failed(Error) }
        let written = await Self.offMain { () -> Written in
            do {
                let stored = try store.loadItemCollections()
                guard let current = stored.first(where: { $0.id == id }) else { return .gone }
                guard let next = change(current, stored) else { return .refused }
                if next != current { try store.saveItemCollection(next) }
                if let record { try store.saveLibraryFolder(record) }
                return .saved(next, current, try? store.loadItemCollections(), record == nil ? nil : try? store.loadLibraryFolders())
            } catch { return .failed(error) }
        }
        switch written {
        case .gone:
            publish(collections.filter { $0.id != id })
            return .gone
        case .refused: return .refused
        case .failed(let error): return .failed(error)
        case .saved(let next, let was, let stored, let storedFolders):
            var local = collections
            if let index = local.firstIndex(where: { $0.id == id }) { local[index] = next } else { local.append(next) }
            var localFolders = folders
            if let record {
                if let index = localFolders.firstIndex(where: { $0.id == record.id }) { localFolders[index] = record } else { localFolders.append(record) }
            }
            onLocalWrite?()
            publish(stored ?? local, folders: record == nil ? nil : (storedFolders ?? localFolders))
            return .saved(next, was: was)
        }
    }

    /// An import's start (#3769): a new collection and its record, the collection first (`LibraryFolderRecord`'s write
    /// order). A re-pick of a place whose collection already exists saves only the record, through `update`, so it can't
    /// write back an older copy of the collection.
    func startImport(_ collection: ItemCollection, isNew: Bool, record: LibraryFolderRecord, store: SQLiteSessionStore) async -> Update {
        guard isNew else { return await update(collection.id, record: record, store: store) { current, _ in current } }
        let result = await Self.offMain { () -> Result<([ItemCollection]?, [LibraryFolderRecord]?), Error> in
            do {
                try store.saveItemCollection(collection)
                try store.saveLibraryFolder(record)
            } catch { return .failure(error) }
            return .success((try? store.loadItemCollections(), try? store.loadLibraryFolders()))
        }
        switch result {
        case .failure(let error):
            return .failed(error)
        case .success(let (stored, storedFolders)):
            var local = collections
            if let index = local.firstIndex(where: { $0.id == collection.id }) { local[index] = collection } else { local.append(collection) }
            var localFolders = folders
            if let index = localFolders.firstIndex(where: { $0.id == record.id }) { localFolders[index] = record } else { localFolders.append(record) }
            onLocalWrite?()
            publish(stored ?? local, folders: storedFolders ?? localFolders)
            return .saved(collection, was: collection)
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

    /// Every collection write runs here, off the main actor (#2256) and one at a time, so a read-change-write in
    /// `update` is never interleaved with another collection write (#3769).
    private static let writer = CollectionWriter()

    private static func offMain<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await writer.run(work)
    }
}

/// Runs the store's synchronous collection writes one at a time, off the main actor (#3769).
private actor CollectionWriter {
    func run<Value: Sendable>(_ work: @Sendable () -> Value) -> Value { work() }
}
