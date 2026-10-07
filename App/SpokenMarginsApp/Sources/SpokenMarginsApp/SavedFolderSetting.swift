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
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        save(bookmark: bookmark, name: url.lastPathComponent, in: defaults)
    }

    /// The saved folder, or nil when none is set. A stale bookmark is refreshed in place.
    func resolvedURL(in defaults: UserDefaults = .standard) throws -> URL? {
        guard let data = bookmark(in: defaults) else { return nil }
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: Self.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let refreshed = try url.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(refreshed, forKey: bookmarkKey)
        }
        return url
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
