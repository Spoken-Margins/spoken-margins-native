import Foundation
import SessionKit

/// Removes the recordings of Margins that were just deleted for good, off the caller's actor (#2507, #2510).
///
/// `MarginRecordingCleanup` decides and removes; what it needs first is every audio path the surviving Margins
/// name (`allMarginAudioPaths`, a scan of every Margin row) and then file work. Permanent delete ran both on the
/// main thread right after the delete. Here the scan and the removals run in one `StoreReader` task, so the scan
/// still sees the delete (it runs after it) and the removals only ever act on that scan's answer.
///
/// If the scan fails nothing is removed: a recording is deleted only once no remaining Margin is known to use it.
public enum MarginRecordingRemoval {
    /// Removes the files only `deletedAudioPaths` named, once the surviving Margins name none of them. `beforeRemoving`
    /// is called with each file just before it goes (the leveled playback copies are found by the recording's content,
    /// so they must go first). Returns what was removed.
    @discardableResult
    public static func removeUnreferenced(
        deletedAudioPaths: [String],
        store: SQLiteSessionStore,
        within root: URL,
        resolve: @escaping @Sendable (String) -> URL?,
        beforeRemoving: @escaping @Sendable (URL) -> Void = { _ in }
    ) async -> [URL] {
        guard !deletedAudioPaths.isEmpty else { return [] }
        let removed = try? await StoreReader(store).read { store -> [URL] in
            let surviving = try store.allMarginAudioPaths()
            let files = MarginRecordingCleanup.filesToRemove(
                deletedAudioPaths: deletedAudioPaths, survivingAudioPaths: surviving, within: root, resolve: resolve)
            for file in files { beforeRemoving(file) }
            return MarginRecordingCleanup.removeFiles(
                deletedAudioPaths: deletedAudioPaths, survivingAudioPaths: surviving, within: root, resolve: resolve)
        }
        return removed ?? []
    }
}
