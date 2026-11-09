import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence

/// The spoken note recorder's call site on the model (#3108). The recording itself is
/// `SpokenNoteRecordingCoordinator`; this only hands it the app's store, microphone permission and Library refresh.
extension Gate1AppModel {
    func makeSpokenNoteRecorderEnvironment() -> SpokenNoteRecorderEnvironment? {
        guard let store = try? requireStore(), let support = try? applicationSupportDirectory() else { return nil }
        return SpokenNoteRecorderEnvironment(
            applicationSupport: support,
            itemWriter: store,
            requestMicrophone: { [weak self] in await self?.requestMicrophonePermission() ?? false },
            prepareToRecord: { [weak self] in
                // Nothing playing means nothing to pause; `pause()` on an idle player would report a failure.
                guard let self, self.snapshot.status.isPlaybackActive else { return }
                self.pause()
            },
            libraryChanged: { [weak self] in
                self?.refreshLibraryRowsInBackground(mustPublish: true) // one saved note, no whole-table read on main (#2505)
            },
            beginBackgroundWork: { Gate2AppState.beginBackgroundTask($0) }
        )
    }

    /// At launch: adds dictation that an ended app left outside its note (a force-quit during a take) to that note and
    /// the Library, off the main thread. Quick when there is nothing to find: it lists one folder.
    func recoverSpokenNotes(store: SQLiteSessionStore) {
        guard let support = try? applicationSupportDirectory() else { return }
        Task.detached(priority: .utility) { [weak self] in
            let recovered = SpokenNoteRecovery.recover(
                in: support, now: Date(),
                measureDurationMs: { SpokenNoteAudioFile.durationMs(of: $0) },
                itemWriter: store
            )
            guard !recovered.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.refreshLibraryRowsInBackground(mustPublish: true) // #2505
            }
        }
    }
}
