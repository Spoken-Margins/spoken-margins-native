import Foundation

/// Finds the collection files (`.json`) inside a picked folder (#2672). The walk is bounded in depth and in how
/// many files it returns, so a huge folder cannot freeze the app, and it says when it stopped early. It reads no
/// file contents: the batch import decodes and size-checks each file as it does for a multi-file pick.
public enum ListeningEditionFolderWalk {
    public static let defaultMaxFiles = 200
    public static let defaultMaxDepth = 4

    public struct Result: Equatable, Sendable {
        /// `.json` files in a stable order, at most `maxFiles`.
        public let urls: [URL]
        /// True when more `.json` files were found than `maxFiles`.
        public let truncated: Bool

        public init(urls: [URL], truncated: Bool) {
            self.urls = urls
            self.truncated = truncated
        }
    }

    /// Returns the `.json` files under `folder`. Hidden files and folders, packages, and other file types are
    /// skipped. A folder that cannot be listed gives an empty result.
    public static func collect(in folder: URL,
                               maxFiles: Int = defaultMaxFiles,
                               maxDepth: Int = defaultMaxDepth) -> Result {
        var found: [URL] = []
        var truncated = false
        walk(folder, depth: 0, maxFiles: maxFiles, maxDepth: maxDepth, found: &found, truncated: &truncated)
        return Result(urls: found, truncated: truncated)
    }

    private static func walk(_ directory: URL, depth: Int, maxFiles: Int, maxDepth: Int,
                             found: inout [URL], truncated: inout Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        let sorted = children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var subfolders: [URL] = []
        for child in sorted {
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if values?.isPackage != true { subfolders.append(child) }
            } else if child.pathExtension.lowercased() == "json" {
                if found.count >= maxFiles { truncated = true; return }
                found.append(child)
            }
        }
        guard depth < maxDepth else { return }
        for sub in subfolders {
            walk(sub, depth: depth + 1, maxFiles: maxFiles, maxDepth: maxDepth, found: &found, truncated: &truncated)
            if truncated { return }
        }
    }

    /// The sentence added to the result when a folder pick was cut short.
    public static func truncationNote(maxFiles: Int = defaultMaxFiles) -> String {
        "The folder holds more than \(maxFiles) collection files, so only the first \(maxFiles) were read. Pick a smaller folder for the rest."
    }

    /// The message when the picked folder holds no `.json` files at all.
    public static func emptyMessage(folderNames: [String]) -> String {
        folderNames.count == 1
            ? "No collection files (.json) were found in \(folderNames[0])."
            : "No collection files (.json) were found in the chosen folders."
    }
}
