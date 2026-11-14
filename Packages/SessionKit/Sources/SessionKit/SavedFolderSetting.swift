import Foundation

/// One folder the listener picked, kept as a bookmark plus its display name in UserDefaults.
///
/// Export Sessions and "Save Margins to Notes Folder" each own one (#930). They used to share the
/// export bookmark, so changing the export folder also moved the notes folder, and the notes feature
/// then copied every existing Margin into the folder picked for a five-session export.
///
/// The settings and their keys live here, where they run on the host. Making and resolving the security-scoped
/// bookmark itself needs Apple's file coordination, so the app adds that in `SavedFolderSetting+Bookmarks.swift` (#318).
public struct SavedFolderSetting: Sendable {
    public let bookmarkKey: String
    public let nameKey: String

    public init(bookmarkKey: String, nameKey: String) {
        self.bookmarkKey = bookmarkKey
        self.nameKey = nameKey
    }

    public static let sessionExport = SavedFolderSetting(bookmarkKey: "batchExportFolderBookmark", nameKey: "batchExportFolderName")
    public static let marginNotes = SavedFolderSetting(bookmarkKey: "marginNotesFolderBookmark", nameKey: "marginNotesFolderName")

    public func hasFolder(in defaults: UserDefaults = .standard) -> Bool { defaults.data(forKey: bookmarkKey) != nil }
    public func name(in defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: nameKey) }
    public func bookmark(in defaults: UserDefaults = .standard) -> Data? { defaults.data(forKey: bookmarkKey) }

    public func save(bookmark: Data, name: String, in defaults: UserDefaults = .standard) {
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(name, forKey: nameKey)
    }

    /// Before #930 the notes feature read the export bookmark. On the first launch with separate
    /// settings, the notes folder starts as that same folder, so notes keep landing where they did;
    /// only later picks diverge. Returns true when it copied.
    @discardableResult
    public static func separateMarginNotesFromSessionExport(defaults: UserDefaults = .standard) -> Bool {
        guard !marginNotes.hasFolder(in: defaults), let bookmark = sessionExport.bookmark(in: defaults) else { return false }
        marginNotes.save(bookmark: bookmark, name: sessionExport.name(in: defaults) ?? "Folder", in: defaults)
        return true
    }
}
