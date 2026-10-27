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
    /// new ones arrive. A reload that started during the read (a tap's background reload or another import's) makes
    /// this answer stale, so it is read again rather than dropped, and the third read publishes unless a newer reload
    /// has already published (that one began after the caller's write, so its rows include it, and this older read
    /// must not land over it). Callers read the published rows after this returns, so it never returns before they
    /// are on screen. The Preparing Audio lists are left alone when their writer (a reorder) changed them during the
    /// read, like the background reload. The read is `navigationLibraryRead`, so a test can hold it open. Returns
    /// whether the rows are on screen, which they are unless the read throws.
    @discardableResult
    func reloadLibraryRowsOffMain(store: SQLiteSessionStore) async throws -> Bool {
        for attempt in 0..<3 {
            let (generation, _) = backgroundRefresh.beginLibraryReload(mustPublish: true)
            let listsBefore = audioPreparationLists
            let data = try await navigationLibraryRead(store)
            let current = backgroundRefresh.isCurrentLibrary(generation)
            if !current {
                if backgroundRefresh.newerLibraryPublished(than: generation) { return true }
                if attempt < 2 { continue }
            }
            publishLibraryRead(data, store: store, generation: generation, publishLists: audioPreparationLists == listsBefore)
            return true
        }
        return false
    }
}
