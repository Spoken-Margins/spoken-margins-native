import Foundation

/// The files in a rendered-speech cache directory: the `.wav` files, named by a digest. Shared by the
/// cache (SessionKitSupertonic) and the ledger's Clear Audio, which empties a directory no cache has open (#313).
public enum RenderedSpeechCacheFiles {
    public struct Entry: Sendable {
        public var url: URL
        public var size: Int
        public var modifiedAt: Date
    }

    public static func entries(in directory: URL, fileManager: FileManager = .default) -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "wav",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return Entry(url: url, size: values.fileSize ?? 0, modifiedAt: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Deletes every cached file and returns the bytes freed.
    public static func removeAll(in directory: URL, fileManager: FileManager = .default) -> Int64 {
        entries(in: directory, fileManager: fileManager).reduce(Int64(0)) { freed, entry in
            (try? fileManager.removeItem(at: entry.url)) == nil ? freed : freed + Int64(entry.size)
        }
    }
}
