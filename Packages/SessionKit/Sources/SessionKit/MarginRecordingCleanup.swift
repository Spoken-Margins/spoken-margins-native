import Foundation

/// Removes the voice recordings of Margins whose item was deleted for good (#1035).
///
/// A spoken Margin keeps its audio as a file that only the Margin's database row names. Deleting an
/// item deleted the rows and left the files on the phone, so "permanently deleted" kept the person's
/// own voice. The caller reads the item's Margin rows before deleting them and, afterwards, every audio
/// path the Margins that stay name (including rows that no longer decode); this removes what only the
/// deleted rows named.
///
/// It only ever removes a regular file that lies inside `root` (the folder the app keeps recordings in)
/// and that no remaining Margin names. A path it can't resolve, a path outside `root`, a folder, and a
/// file a surviving row still points at are all left alone.
public enum MarginRecordingCleanup {
    /// The files that go with `deleted`, once nothing in `survivingAudioPaths` uses them. `resolve` turns a stored
    /// path into the file's current location, or nil when there is no such file.
    public static func filesToRemove(
        deleted: [Interjection],
        survivingAudioPaths: [String],
        within root: URL,
        resolve: (String) -> URL?
    ) -> [URL] {
        let rootPath = canonical(root).path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let keptPaths = Set(survivingAudioPaths)
        let keptFiles = Set(keptPaths.compactMap(resolve).map { canonical($0).path })

        var seen = Set<String>()
        var files: [URL] = []
        for path in deleted.compactMap(\.audioPath) where !keptPaths.contains(path) {
            guard let url = resolve(path) else { continue }
            let file = canonical(url)
            guard file.path.hasPrefix(rootPrefix),
                  !keptFiles.contains(file.path),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  seen.insert(file.path).inserted else { continue }
            files.append(file)
        }
        return files
    }

    /// Removes those files. A file that can't be removed doesn't stop the rest. Returns what was removed.
    @discardableResult
    public static func removeFiles(
        deleted: [Interjection],
        survivingAudioPaths: [String],
        within root: URL,
        fileManager: FileManager = .default,
        resolve: (String) -> URL?
    ) -> [URL] {
        filesToRemove(deleted: deleted, survivingAudioPaths: survivingAudioPaths, within: root, resolve: resolve).filter { file in
            (try? fileManager.removeItem(at: file)) != nil
        }
    }

    /// Symlinks followed, so `/var` and `/private/var` compare equal and a link can't point out of `root`.
    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
