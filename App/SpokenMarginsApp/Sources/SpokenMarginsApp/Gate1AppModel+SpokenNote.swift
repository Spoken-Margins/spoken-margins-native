import Foundation
import SessionKit
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
                guard let self, let store = self.store else { return }
                try? self.refreshLibraryRows(store: store)
            },
            beginBackgroundWork: { Gate2AppState.beginBackgroundTask($0) }
        )
    }
}
