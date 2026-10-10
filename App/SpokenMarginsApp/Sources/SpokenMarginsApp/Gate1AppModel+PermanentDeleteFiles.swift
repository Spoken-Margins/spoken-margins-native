import Foundation
import SessionKit
import SessionKitPersistence

/// The files that go with an item when it is deleted for good.
extension Gate1AppModel {
    /// Removes the spoken Margin recordings of Margins whose rows were just deleted (#1035). The rows were
    /// read before the delete; `store` now holds only the Margins that stay. If every audio path those name
    /// can't be read (a row that no longer decodes still counts), nothing is removed: a recording is only
    /// deleted once no remaining Margin is known to use it. Only files under `SpokenMargins/`, where the
    /// recorder keeps them, are ever removed.
    func removeMarginRecordings(_ deleted: [Interjection], store: SQLiteSessionStore) {
        guard !deleted.isEmpty,
              let surviving = try? store.allMarginAudioPaths(),
              let supportDirectory = try? applicationSupportDirectory() else { return }
        let recordings = supportDirectory.appending(path: "SpokenMargins", directoryHint: .isDirectory)
        // The leveled playback copies (#467) are the same voice. They are found by the recording's content,
        // so they go before the recording does.
        for file in MarginRecordingCleanup.filesToRemove(
            deleted: deleted, survivingAudioPaths: surviving, within: recordings, resolve: resolvedInterjectionAudioURL(for:)
        ) {
            Self.leveledMargins.removeCopies(of: file)
        }
        MarginRecordingCleanup.removeFiles(
            deleted: deleted, survivingAudioPaths: surviving, within: recordings,
            resolve: resolvedInterjectionAudioURL(for:)
        )
    }

    func removeDurableGeneratedAudio(for item: Item) {
        guard item.media?.sourceType == .generatedTTSPrerendered,
              let identifier = item.media?.nativeMediaId ?? item.media?.url,
              let url = URL(string: identifier),
              url.isFileURL,
              let supportDirectory = try? applicationSupportDirectory() else { return }
        let generatedDirectory = supportDirectory
            .appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            .standardizedFileURL
        let file = url.standardizedFileURL
        guard file.deletingLastPathComponent() == generatedDirectory else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
