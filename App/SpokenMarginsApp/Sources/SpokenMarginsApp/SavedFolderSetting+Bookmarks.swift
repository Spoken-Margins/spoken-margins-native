import Foundation
import SessionKit

/// The security-scoped bookmark half of `SavedFolderSetting` (#930). The settings and their keys are in SessionKit
/// (#318); making and resolving a bookmark needs Apple's file APIs, so it stays in the app.
extension SavedFolderSetting {
    /// Bookmarks a folder the listener picked and saves it under this setting with its name.
    func save(folder url: URL, in defaults: UserDefaults = .standard) throws {
        save(bookmark: try Self.makeBookmark(for: url), name: url.lastPathComponent, in: defaults)
    }

    /// The saved folder, or nil when none is set. A stale bookmark is refreshed in place.
    func resolvedURL(in defaults: UserDefaults = .standard) throws -> URL? {
        guard let data = bookmark(in: defaults) else { return nil }
        let resolved = try Self.resolve(bookmark: data)
        if let refreshed = resolved.refreshedBookmark { defaults.set(refreshed, forKey: bookmarkKey) }
        return resolved.url
    }

    /// A bookmark for a folder the listener just picked.
    static func makeBookmark(for url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder a bookmark points to, with a fresh bookmark when the saved one had gone stale. Throws when the
    /// folder can no longer be reached (deleted, or access revoked).
    static func resolve(bookmark data: Data) throws -> (url: URL, refreshedBookmark: Data?) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard isStale else { return (url, nil) }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return (url, try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// The folder's name from a bookmark, without resolving it, so a folder the app has lost access to still has a name.
    static func folderName(inBookmark data: Data) -> String? {
        guard let values = try? URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: data) else { return nil }
        return values.name
    }

    #if os(macOS)
    private static var creationOptions: URL.BookmarkCreationOptions { [.withSecurityScope] }
    private static var resolutionOptions: URL.BookmarkResolutionOptions { [.withSecurityScope] }
    #else
    private static var creationOptions: URL.BookmarkCreationOptions { [] }
    private static var resolutionOptions: URL.BookmarkResolutionOptions { [] }
    #endif
}
