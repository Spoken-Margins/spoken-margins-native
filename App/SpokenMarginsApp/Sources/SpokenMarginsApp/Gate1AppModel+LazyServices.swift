import Foundation
import SessionKit
import SessionKitPersistence

extension Gate1AppModel {
    func requireOfflineLedger(
        store: SQLiteSessionStore,
        rootDirectory: @autoclosure () throws -> URL
    ) rethrows -> OfflineStorageLedger {
        if let offlineStorageLedger { return offlineStorageLedger }
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: try rootDirectory())
        offlineStorageLedger = ledger
        return ledger
    }

    /// The prepared-audio coordinator, created on first use under `<support>/PreparedAudio` and kept.
    /// `makeSpeechPlaybackClient` still replaces it unconditionally (#1003).
    func requirePreparedAudioCoordinator(store: SQLiteSessionStore, supportDirectory: URL) -> PreparedAudioCoordinator {
        if let preparedAudioCoordinator { return preparedAudioCoordinator }
        let coordinator = PreparedAudioCoordinator(
            repository: store,
            rootDirectory: supportDirectory.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        )
        preparedAudioCoordinator = coordinator
        return coordinator
    }

    /// The followed-source coordinator, created on first use and kept. Only `configureOfflineServices`
    /// passes the artwork file; this fallback never does, as before (#1003).
    func requireFollowedSourceCoordinator(store: SQLiteSessionStore) -> FollowedSourceCoordinator {
        if let followedSourceCoordinator { return followedSourceCoordinator }
        let coordinator = FollowedSourceCoordinator(repository: store)
        followedSourceCoordinator = coordinator
        return coordinator
    }
}
