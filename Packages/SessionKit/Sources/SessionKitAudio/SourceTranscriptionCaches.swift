import Foundation

/// Regenerable audio exports shared by the transcriber and its cleanup callers.
public enum SourceTranscriptionCaches {
    public enum Folder: String, CaseIterable {
        case chunks = "SourceAudioTranscriptionChunksV3"
        case windows = "SourceAudioTranscriptionWindows"
    }

    public static func directory(
        for folder: Folder,
        itemId: String,
        cachesDirectory: URL
    ) -> URL {
        cachesDirectory.appending(path: "\(folder.rawValue)/\(itemId)", directoryHint: .isDirectory)
    }

    public static func purge(itemId: String, cachesDirectory: URL? = nil) throws {
        let caches = try cachesDirectory ?? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        for folder in Folder.allCases {
            let url = directory(for: folder, itemId: itemId, cachesDirectory: caches)
            if FileManager.default.fileExists(atPath: url.path) {
                try remove(folder, itemId: itemId, cachesDirectory: caches)
            }
        }
    }

    /// Removes one folder so best-effort callers can catch each failure independently.
    public static func remove(_ folder: Folder, itemId: String, cachesDirectory: URL) throws {
        try FileManager.default.removeItem(at: directory(for: folder, itemId: itemId, cachesDirectory: cachesDirectory))
    }
}
