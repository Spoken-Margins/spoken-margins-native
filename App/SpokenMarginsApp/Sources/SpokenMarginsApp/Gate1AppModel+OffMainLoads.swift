import Foundation
import SessionKit
import SessionKitPersistence

/// Async twins of `loadItemDetail` and `loadLibraryRows` for callers that are already in a `Task` (#2507). The read
/// runs on `StoreReader`'s background task; the result applies back here on the main actor. The synchronous
/// versions stay for flows that read the result on the next line.
extension Gate1AppModel {
    /// One item's detail, read off the main thread. The caller checks that its screen still wants the result.
    func loadItemDetailOffMain(id: String, store: SQLiteSessionStore) async throws -> ItemDetailState {
        let snapshotItemId = snapshot.itemId
        let snapshotSessionId = snapshot.sessionId
        let passes = sharedMarginPlacementPasses
        return try await StoreReader(store).read(priority: .userInitiated) {
            try ItemDetailLoader.load(
                id: id, store: $0, snapshotItemId: snapshotItemId,
                snapshotSessionId: snapshotSessionId, placementPasses: passes)
        }
    }

    /// Reloads the Library rows off the main thread and publishes them, keeping the previous rows on screen until the
    /// new ones arrive. A newer reload that started during the read wins and carries the publish obligation, so the
    /// older answer is dropped. Returns whether this reload published.
    @discardableResult
    func reloadLibraryRowsOffMain(store: SQLiteSessionStore) async throws -> Bool {
        let (generation, _) = backgroundRefresh.beginLibraryReload(mustPublish: true)
        let data = try await StoreReader(store).read(priority: .userInitiated) { try LibraryReadSnapshot.read(store: $0) }
        guard backgroundRefresh.isCurrentLibrary(generation) else { return false }
        publishLibrary(data)
        backgroundRefresh.libraryWasPublished()
        return true
    }
}
