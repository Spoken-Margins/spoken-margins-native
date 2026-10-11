import Foundation

/// One folder the listener picked, kept as a bookmark plus its display name in UserDefaults.
///
/// Export Sessions and "Save Margins to Notes Folder" each own one (#930). They used to share the
/// export bookmark, so changing the export folder also moved the notes folder, and the notes feature
/// then copied every existing Margin into the folder picked for a five-session export.
struct SavedFolderSetting: Sendable {
    let bookmarkKey: String
    let nameKey: String

    static let sessionExport = SavedFolderSetting(bookmarkKey: "batchExportFolderBookmark", nameKey: "batchExportFolderName")
    static let marginNotes = SavedFolderSetting(bookmarkKey: "marginNotesFolderBookmark", nameKey: "marginNotesFolderName")

    func hasFolder(in defaults: UserDefaults = .standard) -> Bool { defaults.data(forKey: bookmarkKey) != nil }
    func name(in defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: nameKey) }
    func bookmark(in defaults: UserDefaults = .standard) -> Data? { defaults.data(forKey: bookmarkKey) }

    func save(bookmark: Data, name: String, in defaults: UserDefaults = .standard) {
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(name, forKey: nameKey)
    }

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

    /// Before #930 the notes feature read the export bookmark. On the first launch with separate
    /// settings, the notes folder starts as that same folder, so notes keep landing where they did;
    /// only later picks diverge. Returns true when it copied.
    @discardableResult
    static func separateMarginNotesFromSessionExport(defaults: UserDefaults = .standard) -> Bool {
        guard !marginNotes.hasFolder(in: defaults), let bookmark = sessionExport.bookmark(in: defaults) else { return false }
        marginNotes.save(bookmark: bookmark, name: sessionExport.name(in: defaults) ?? "Folder", in: defaults)
        return true
    }
}
