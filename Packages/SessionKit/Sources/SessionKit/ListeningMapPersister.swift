import Foundation

/// What `ListeningMapPersister.persist` saved: the item as it is now stored and the map attached to it.
public struct PersistedListeningMap: Sendable {
    public let item: Item
    public let map: ListeningMap
}

/// The store steps of attaching a Listening Map (#2509): load the item, save the map, and mark an item that was
/// waiting for a map as ready. They can take long for a large text, so a caller runs them off the main thread and
/// then hands the result to `SessionEngine.attachListeningMap(_:)` on it. The steps keep their old order.
public struct ListeningMapPersister: Sendable {
    let repository: any SessionRepository
    /// Runs after the item is loaded and before the map is saved. A test uses it to hold the persist at that point
    /// while a delete is asked on another thread; nothing in the app sets it.
    var afterLoad: (@Sendable () -> Void)?

    init(repository: any SessionRepository, afterLoad: (@Sendable () -> Void)? = nil) {
        self.repository = repository
        self.afterLoad = afterLoad
    }

    /// Load, save and status flip are one transaction, so a permanent delete asked while a map job finishes lands
    /// before the load (the item is gone, this throws and writes nothing) or after the commit (the delete takes the
    /// map and the item with it). Before, the load and the saves were separate, and a delete between them let the
    /// saves write the map and the item back (#4227).
    public func persist(_ map: ListeningMap) throws -> PersistedListeningMap {
        let write = { () throws -> PersistedListeningMap in
            var item = try repository.loadItem(id: map.itemId)
            afterLoad?()
            try repository.saveListeningMap(map)
            if item.status == "needs_listening_map" {
                item.status = "ready"
                try repository.saveItem(item)
            }
            return PersistedListeningMap(item: item, map: map)
        }
        if let store = repository as? any SessionRepositoryTransaction { return try store.withSessionTransaction(write) }
        return try write()
    }
}
