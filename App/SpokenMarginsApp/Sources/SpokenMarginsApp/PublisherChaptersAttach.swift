import Foundation
import SessionKit

/// Attaches an imported podcast's publisher chapters with the store steps off the main thread (#2509), as
/// `SharedTextMapAttach` does for a shared map. Only the engine half runs on the main actor.
@MainActor
enum PublisherChaptersAttach {
    /// Called inside the store work, so a test can see which thread it runs on.
    nonisolated(unsafe) static var observeWrite: (@Sendable () -> Void)?

    /// Builds the persister on main, runs it off main, and applies the result on main. An engine replaced while it
    /// ran is not told: the chapters are saved, and the replacement engine reads them when the item opens.
    static func attach(_ collection: PublisherChapterCollection, itemId: String, engine: SessionEngine, model: Gate1AppModel) async throws {
        let persister = try engine.publisherChaptersPersister(itemId: itemId)
        let observe = observeWrite
        let persisted = try await Gate1AppModel.offMain { () -> PersistedPublisherChapters? in
            observe?()
            return try persister.persist(itemId: itemId, collection: collection)
        }
        guard engine === model.engine else { return }
        _ = try engine.attachPublisherChapters(persisted)
    }
}
