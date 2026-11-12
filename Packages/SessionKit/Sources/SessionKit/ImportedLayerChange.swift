import Foundation

/// A change to a friend's layer that must not carry an older copy of the rest of the layer with it (#3601).
///
/// A caller that loads a layer, changes a field and saves the whole layer has two store calls with a gap between them.
/// A repair, a share-link back-fill or another switch that commits in that gap is undone when the earlier copy is saved.
/// Everything that loads a layer in order to save it again goes through here, so the load and the save are one
/// transaction: the layer is read after the write lock is taken, and nothing else can commit between the two.
public enum ImportedLayerChange {
    /// Runs `body` as one transaction when the repository has them (the SQLite store), and joins one already open.
    /// A repository without transactions (the in-memory one, single-threaded) just runs it.
    public static func underWriteLock<T>(on repository: ListeningSessionRepository, _ body: () throws -> T) throws -> T {
        if let store = repository as? any SessionRepositoryTransaction { return try store.withSessionTransaction(body) }
        return try body()
    }

    /// Changes one layer as it is stored now. Returns false, and changes nothing, when the layer is gone.
    @discardableResult
    public static func apply(
        toLayerWithId layerId: String,
        on repository: ListeningSessionRepository,
        _ mutation: (inout ImportedCommentaryLayer) -> Void
    ) throws -> Bool {
        try underWriteLock(on: repository) {
            guard var layer = try repository.loadImportedCommentaryLayer(id: layerId) else { return false }
            mutation(&layer)
            try repository.saveImportedCommentaryLayer(layer)
            return true
        }
    }
}
