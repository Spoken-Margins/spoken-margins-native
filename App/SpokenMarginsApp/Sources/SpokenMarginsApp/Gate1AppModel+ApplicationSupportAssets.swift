import Foundation

/// Where stored Margin audio and other Application Support assets live now. Moved out of
/// Gate1AppModel.swift unchanged (#483 made room for its call sites under the hot-file ratchet).
extension Gate1AppModel {
    /// Stored Margin audio paths may be absolute paths from an earlier app container
    /// (container UUIDs change on reinstall, restore, and some updates). Rebase them onto
    /// the current Application Support directory instead of failing.
    nonisolated static func resolvedInterjectionAudioURL(
        for path: String,
        applicationSupportDirectory: URL?
    ) -> URL? {
        if path.hasPrefix("interjections/"), let applicationSupportDirectory {
            let legacyURL = applicationSupportDirectory.appending(path: "SpokenMargins").appending(path: path)
            if FileManager.default.fileExists(atPath: legacyURL.path) { return legacyURL }
        }
        return resolvedApplicationSupportAssetURL(
            for: path, applicationSupportDirectory: applicationSupportDirectory
        )
    }

    nonisolated static func resolvedApplicationSupportAssetURL(
        for path: String,
        applicationSupportDirectory: URL?
    ) -> URL? {
        let fileManager = FileManager.default
        let directURL = URL(fileURLWithPath: path)
        if directURL.isFileURL, fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }
        guard let applicationSupportDirectory else { return nil }
        let supportMarker = "/Library/Application Support/"
        if let markerRange = path.range(of: supportMarker) {
            let relativePath = String(path[markerRange.upperBound...])
            let relocatedURL = applicationSupportDirectory.appending(path: relativePath)
            if fileManager.fileExists(atPath: relocatedURL.path) {
                return relocatedURL
            }
        }
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let relativeURL = applicationSupportDirectory.appending(path: relativePath)
        return fileManager.fileExists(atPath: relativeURL.path) ? relativeURL : nil
    }
}
