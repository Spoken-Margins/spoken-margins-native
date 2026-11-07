import Foundation
import SessionKit
import SessionKitPersistence

/// Attaches a shared Listening Map to a text item with the store steps off the main thread (#2509), as a Listening
/// Edition's map is (`Gate1AppModel.attachListeningEditionMap`). Only the engine half runs on the main actor.
@MainActor
enum SharedTextMapAttach {
    /// Called inside the store write, so a test can see which thread it runs on.
    nonisolated(unsafe) static var observeWrite: (@Sendable () -> Void)?

    static func attach(_ map: ListeningMap, model: Gate1AppModel) async throws {
        func playingNow() -> Bool { model.snapshot.itemId == map.itemId && model.snapshot.status.isPlaybackActive }
        // A map can't change under playback: refused before anything is saved.
        if playingNow() { throw SessionKitError.persistenceFailed("shared_map_item_is_playing") }
        let engine = model.engine
        let persister = try engine?.listeningMapPersister()
        let store = try model.requireStore()
        let observe = observeWrite
        let persisted = try await Gate1AppModel.offMain { () -> PersistedListeningMap? in
            observe?()
            if let persister { return try persister.persist(map) }
            try store.saveListeningMap(map)
            return nil
        }
        // The listener may have pressed play while the write ran: the map is saved, and the engine takes it the next
        // time the item opens, as for an edition's map. An engine replaced meanwhile is not told.
        if let engine, engine === model.engine, let persisted, !playingNow() { model.snapshot = try engine.attachListeningMap(persisted) }
    }
}
