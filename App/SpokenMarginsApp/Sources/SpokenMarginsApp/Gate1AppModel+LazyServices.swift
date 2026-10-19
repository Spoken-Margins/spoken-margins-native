import Foundation
import SessionKit
import SessionKitFeeds
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

    /// Settings › Voices (#1819), created on first use and kept, so a download outlives the screen. An
    /// installed or removed voice refreshes Storage and the screens that list voices. The player follows the files
    /// itself (#1820): a removed Supertonic's renderer is unloaded here, and the next play uses what is there.
    func requireVoiceDownloads() -> VoiceDownloadsModel {
        if let voiceDownloadsModel { return voiceDownloadsModel }
        let support = (try? applicationSupportDirectory()) ?? FileManager.default.temporaryDirectory
        let model = VoiceDownloadsModel.make(supportDirectory: support, repository: try? requireStore())
        model.onInstalledVoicesChanged = { [weak self] in
            guard let self else { return }
            self.tryRefreshOfflineStorageUsage()
            self.supertonicModel.retireIfReplaced()
            self.refreshSupertonicSessionDiagnostics()
            self.objectWillChange.send()
        }
        voiceDownloadsModel = model
        return model
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
        let coordinator = FollowedSourceCoordinator(repository: store, signals: .app)
        followedSourceCoordinator = coordinator
        return coordinator
    }
}
