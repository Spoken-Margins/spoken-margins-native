import Foundation

/// The Margins tab's "Paper notes table" export (#4340 PR 6 of the Design): which papers it covers, the words of its
/// dialog, and the file it hands to the share sheet. The table itself is `PaperNoteTable`.
public enum PaperNoteTableExport {
    public enum Format: CaseIterable, Sendable {
        case markdown, csv

        /// The dialog's button.
        public var buttonTitle: String {
            switch self {
            case .markdown: "Markdown"
            case .csv: "CSV for spreadsheets"
            }
        }

        public var fileName: String {
            switch self {
            case .markdown: "Paper notes.md"
            case .csv: "Paper notes.csv"
            }
        }
    }

    public static let menuTitle = "Paper notes table"
    public static let dialogTitle = "Paper notes table"
    public static let failed = "The paper notes table can't be made right now."

    /// What the dialog calls the tab's scope: the collection's or item's name, or "your whole Library" for Everything.
    public static func scopeName(_ query: MarginCollectionQuery, collectionName: String?, itemTitle: String?) -> String {
        if query.collection != nil { return clean(collectionName) ?? "this collection" }
        if query.itemID != nil { return clean(itemTitle) ?? "Untitled" }
        return "your whole Library"
    }

    /// "One row per paper with a paper note, in <scope name>."
    public static func dialogMessage(scopeName: String) -> String {
        "One row per paper with a paper note, in \(scopeName)."
    }

    /// The papers a table in this scope can have a row for: the items among `itemIDs` that the tab's collection or item
    /// scope includes. Search text and the All/Shared filter don't narrow it: the dialog names only the scope.
    public static func scope(_ query: MarginCollectionQuery, itemIDs: some Sequence<String>) -> Set<String> {
        Set(itemIDs.filter { query.includes(itemID: $0) })
    }

    /// Whether any of the listener's own Margins in `margins` gives a paper a row: the menu item is off otherwise. Margins
    /// whose item isn't a paper are passed out by the caller.
    public static func hasAnswers(_ margins: some Sequence<Interjection>, scope: Set<String>) -> Bool {
        margins.contains { margin in
            margin.paperRole != nil && scope.contains(margin.itemId) && PaperNoteOrder.isOwnOnPaper(margin, itemId: margin.itemId)
        }
    }

    /// The file's bytes: the Markdown table as UTF-8, the CSV with a byte order mark.
    public static func data(_ table: PaperNoteTable, format: Format) -> Data {
        switch format {
        case .markdown: Data(table.markdown().utf8)
        case .csv: table.csvData()
        }
    }

    /// Writes the table into a fresh folder under `directory`, so two exports never collide, and returns the file's URL
    /// for the share sheet. The sheet's close removes the folder, as for every Margins export (#1528).
    public static func write(_ table: PaperNoteTable, format: Format, under directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(format.fileName, isDirectory: false)
        try data(table, format: format).write(to: url, options: .atomic)
        return url
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
