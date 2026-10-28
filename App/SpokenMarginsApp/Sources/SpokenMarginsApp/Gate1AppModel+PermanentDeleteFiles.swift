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
    ///
    /// `quarantinedAudioPaths` are the recordings of the item's Margins that were set aside because they
    /// couldn't be decoded (`SQLiteSessionStore.quarantinedMarginAudioPaths`, read before the delete, #1466).
    ///
    /// The surviving-paths scan and the file removals run on `StoreReader`'s background task (#2507, #2510), so
    /// permanent delete no longer waits on them. A recording whose removal is still pending when the app is killed
    /// stays on disk, as one whose removal failed always did.
    func removeMarginRecordings(_ deleted: [Interjection], quarantinedAudioPaths: [String] = [], store: SQLiteSessionStore) {
        let deletedAudioPaths = deleted.compactMap(\.audioPath) + quarantinedAudioPaths
        guard !deletedAudioPaths.isEmpty,
              let supportDirectory = try? applicationSupportDirectory() else { return }
        let recordings = supportDirectory.appending(path: "SpokenMargins", directoryHint: .isDirectory)
        let resolve: @Sendable (String) -> URL? = {
            Self.resolvedInterjectionAudioURL(for: $0, applicationSupportDirectory: supportDirectory)
        }
        let leveledMargins = Self.leveledMargins
        Task {
            await MarginRecordingRemoval.removeUnreferenced(
                deletedAudioPaths: deletedAudioPaths, store: store, within: recordings, resolve: resolve,
                // The leveled playback copies (#467) are the same voice. They are found by the recording's
                // content, so they go before the recording does.
                beforeRemoving: { leveledMargins.removeCopies(of: $0) }
            )
        }
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
