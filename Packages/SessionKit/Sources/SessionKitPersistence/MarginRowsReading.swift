import Foundation
import SessionKit

/// Reads the Margins list rows, all of them or one item's (#2505). Synchronous and made to be called inside
/// `StoreReader.read`, so the main thread never waits on it.
public enum MarginRowsReading {
    /// Every item's rows: the Margins tab opening, pull to refresh.
    public static func all(store: SQLiteSessionStore) throws -> MarginCollection.Entries {
        try MarginCollection.build(
            items: store.listItems(), sessions: store.loadSessions(),
            loadMap: { try? store.loadListeningMap(itemId: $0) },
            loadMediaChapters: { (try? store.loadTranscriptTimelineChapters(itemId: $0)) ?? [] },
            loadInterjections: { try store.loadInterjections(sessionId: $0) },
            loadImportedLayers: { try store.loadImportedCommentaryLayers() },
            loadImportedInterjections: { try store.loadImportedCommentaryInterjections(layerId: $0) })
    }

    /// One item's rows, the same rows `all` gives for it. An item that is trashed or gone has none, so applying
    /// the result removes its Margins; once it is restored the same read brings them back.
    public static func item(_ itemId: String, store: SQLiteSessionStore) throws -> MarginCollection.Entries {
        guard let item = try? store.loadItem(id: itemId) else {
            return MarginCollection.Entries(privateRows: [], sharedRows: [])
        }
        return try MarginCollection.build(
            items: [item], sessions: store.loadSessions(itemId: itemId),
            loadMap: { try? store.loadListeningMap(itemId: $0) },
            loadMediaChapters: { (try? store.loadTranscriptTimelineChapters(itemId: $0)) ?? [] },
            loadInterjections: { try store.loadInterjections(sessionId: $0) },
            loadImportedLayers: { try store.loadImportedCommentaryLayers(itemId: itemId) },
            loadImportedInterjections: { try store.loadImportedCommentaryInterjections(layerId: $0) })
    }
}
