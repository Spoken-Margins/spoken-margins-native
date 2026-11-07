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

    public func persist(_ map: ListeningMap) throws -> PersistedListeningMap {
        var item = try repository.loadItem(id: map.itemId)
        try repository.saveListeningMap(map)
        if item.status == "needs_listening_map" {
            item.status = "ready"
            try repository.saveItem(item)
        }
        return PersistedListeningMap(item: item, map: map)
    }
}
