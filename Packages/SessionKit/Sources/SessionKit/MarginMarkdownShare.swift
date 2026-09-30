import Foundation

extension ExportOptions {
    /// The export behind one Margin's Markdown note. The notes folder (#161) and "Share as
    /// Markdown" (#493) both use it, so a shared file is the same note the folder gets.
    public static func marginNote(sessionId: String, marginId: String) -> ExportOptions {
        ExportOptions(
            sessionId: sessionId,
            includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false,
            scope: "selected_interjections", interjectionIds: [marginId]
        )
    }
}

/// A named Markdown file to hand to the share sheet.
public struct MarginMarkdownFile: Equatable, Sendable {
    public var fileName: String
    public var markdown: String

    public init(fileName: String, markdown: String) {
        self.fileName = fileName
        self.markdown = markdown
    }
}

/// "Share as Markdown" for one Margin or an item's Margins (#493): the notes-folder note, as a
/// file named for the item, for Notion, Bear, Drafts or Files.
public enum MarginMarkdownShare {
    /// Between the notes of an item's file. Not `---`, which would read as another YAML block
    /// once notes start with #491's properties.
    public static let separator = "\n* * *\n\n"

    /// A file name may be 255 UTF-8 bytes; the title's share leaves room for `Margin - … - 1h02m03s.md`.
    static let maximumTitleBytes = 150

    /// Whether a Margin gets a note: active, with something written or transcribed, as in the notes folder.
    public static func hasNote(_ margin: Interjection) -> Bool {
        margin.status == "active"
            && !(margin.cleanedTranscript ?? margin.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One Margin's note, named `Margin - <item title> - <position>.md`. Nil when it has no note.
    public static func file(for margin: Interjection, engine: SessionEngine) throws -> MarginMarkdownFile? {
        guard hasNote(margin) else { return nil }
        let export = try engine.buildExport(options: .marginNote(sessionId: margin.sessionId, marginId: margin.id))
        let markdown = SessionExportMarkdownRenderer.renderMargin(export, createdAt: margin.createdAt)
        guard !markdown.isEmpty, let note = export.interjections.first else { return nil }
        return MarginMarkdownFile(
            fileName: "Margin - \(safeName(export.item.title)) - \(position(of: note)).md",
            markdown: markdown
        )
    }

    /// Every active Margin of one item, in the order they sit in the source, as one file named
    /// `Margins - <item title>.md`. Nil when the item has no Margin with a note.
    public static func file(forItemMargins margins: [Interjection], engine: SessionEngine) throws -> MarginMarkdownFile? {
        let ordered = margins.filter(hasNote).sorted {
            ($0.roughPercent, $0.anchor.mediaTimeMs ?? 0, $0.createdAt, $0.id)
                < ($1.roughPercent, $1.anchor.mediaTimeMs ?? 0, $1.createdAt, $1.id)
        }
        var title: String?
        var notes: [String] = []
        for margin in ordered {
            let export = try engine.buildExport(options: .marginNote(sessionId: margin.sessionId, marginId: margin.id))
            let markdown = SessionExportMarkdownRenderer.renderMargin(export, createdAt: margin.createdAt)
            guard !markdown.isEmpty else { continue }
            title = title ?? export.item.title
            notes.append(markdown)
        }
        guard let title, !notes.isEmpty else { return nil }
        return MarginMarkdownFile(fileName: "Margins - \(safeName(title)).md", markdown: notes.joined(separator: separator))
    }

    /// Writes the file into a fresh folder under `directory`, so two shares with the same name
    /// never collide, and returns its URL for the share sheet.
    public static func write(_ file: MarginMarkdownFile, under directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file.fileName, isDirectory: false)
        try Data(file.markdown.utf8).write(to: url, options: .atomic)
        return url
    }

    /// `12m04s` (or `1h02m03s`) from the media time; the rough percent when there is none.
    /// No colon: Files and some share targets treat `:` as a path separator.
    static func position(of note: ExportInterjection) -> String {
        guard let ms = note.mediaTimeMs else { return "\(note.roughPercent)%" }
        let seconds = max(0, ms / 1000)
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        let tail = String(format: "%02dm%02ds", minutes, rest)
        return hours > 0 ? "\(hours)h\(tail)" : tail
    }

    /// A title that is safe as part of a file name on iOS, macOS and Windows: path and reserved
    /// characters and control characters become `-`, line breaks and runs of spaces become one space, leading dots
    /// and trailing dots and spaces go, and it is cut to 150 UTF-8 bytes without splitting a
    /// character, which leaves room for the rest of the name under the 255-byte limit.
    static func safeName(_ title: String) -> String {
        let reserved = Set("/\\:*?\"<>|")
        var name = ""
        for character in title {
            if character.isWhitespace {
                if !name.hasSuffix(" ") { name.append(" ") }
            } else if reserved.contains(character) || character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                name.append("-")
            } else {
                name.append(character)
            }
        }
        var cut = ""
        for character in name {
            guard cut.utf8.count + String(character).utf8.count <= maximumTitleBytes else { break }
            cut.append(character)
        }
        name = cut
        while let first = name.first, first == "." || first == " " { name.removeFirst() }
        while let last = name.last, last == "." || last == " " { name.removeLast() }
        return name.isEmpty ? "Untitled" : name
    }
}
