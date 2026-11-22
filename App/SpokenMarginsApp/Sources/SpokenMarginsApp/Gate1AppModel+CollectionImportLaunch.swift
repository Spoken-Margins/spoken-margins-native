import Foundation
import SessionKit
import SessionKitPersistence

extension Gate1AppModel {
    /// At launch, before the Library is shown (#3769): an import the app was ended in the middle of is settled
    /// (`LibraryFolderLaunchRule`), and a record whose collection an older build deleted is dropped
    /// (`LibraryFolderOrphanRule`). Returns the snapshot with what was saved, so the first draw already shows it.
    /// A save that fails leaves things as they were for the next launch; nothing here deletes an item.
    func settleCollectionImports(_ data: LibraryReadSnapshot, store: SQLiteSessionStore) -> LibraryReadSnapshot {
        guard let folders = data.libraryFolders, !folders.isEmpty, var collections = data.collections else { return data }
        var data = data
        var kept: [LibraryFolderRecord] = []
        let orphans = Set(LibraryFolderOrphanRule.orphanedFolderIDs(folders: folders, collections: collections))
        let existingItemIDs = Set(data.items.map(\.id))
        for folder in folders {
            if orphans.contains(folder.id) {
                if (try? store.deleteLibraryFolder(id: folder.id)) == nil { kept.append(folder) }
                continue
            }
            guard let index = collections.firstIndex(where: { $0.id == folder.id }) else { kept.append(folder); continue }
            let resolved = LibraryFolderLaunchRule.resolved(folder, collection: collections[index], existingItemIDs: existingItemIDs)
            guard resolved.record != folder || resolved.collection != collections[index] else { kept.append(folder); continue }
            do {
                if resolved.collection != collections[index] { try store.saveItemCollection(resolved.collection) }
                try store.saveLibraryFolder(resolved.record)
                collections[index] = resolved.collection
                kept.append(resolved.record)
            } catch {
                diagnostics["collectionImportLaunchFailure"] = SafeErrorText.describe(error)
                kept.append(folder)
            }
        }
        data.collections = collections
        data.libraryFolders = kept
        return data
    }
}
