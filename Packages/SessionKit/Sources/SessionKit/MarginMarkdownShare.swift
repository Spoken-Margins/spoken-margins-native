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

    /// Whether a Margin gets a note, as in the notes folder: active, and spoken or with something written (#171).
    public static func hasNote(_ margin: Interjection) -> Bool {
        margin.status == "active" && SessionExportMarkdownRenderer.writesMarginNote(
            captureKind: margin.captureKind, text: margin.cleanedTranscript ?? margin.transcript
        )
    }

    /// The notes folder's note for one Margin, dated as the folder dates it (#624).
    static func note(for margin: Interjection, engine: SessionEngine, source: SessionEngine.ExportSource? = nil) throws -> (SessionExport, String) {
        let options = ExportOptions.marginNote(sessionId: margin.sessionId, marginId: margin.id)
        let export = try source.map { try engine.buildExport(options: options, source: $0) } ?? engine.buildExport(options: options)
        let session = try source?.session ?? engine.loadSession(id: margin.sessionId)
        let recordedAt = margin.recordedAt(in: session)
        return (export, SessionExportMarkdownRenderer.renderMargin(export, createdAt: recordedAt))
    }

    /// One Margin's note, named `Margin - <item title> - <position>.md`. Nil when it has no note.
    public static func file(for margin: Interjection, engine: SessionEngine) throws -> MarginMarkdownFile? {
        guard hasNote(margin) else { return nil }
        let (export, markdown) = try note(for: margin, engine: engine)
        guard !markdown.isEmpty, let note = export.interjections.first else { return nil }
        return MarginMarkdownFile(
            fileName: "Margin - \(safeName(export.item.title)) - \(position(of: note)).md",
            markdown: markdown
        )
    }

    /// Every active Margin of one item, in the order they sit in the source, as one file named
    /// `Margins - <item title>.md`. Nil when the item has no Margin with a note.
    public static func file(forItemMargins margins: [Interjection], engine: SessionEngine) throws -> MarginMarkdownFile? {
        var notes: [(margin: Interjection, export: SessionExport, markdown: String)] = []
        // The item and its transcript timeline are read once per session, not once per Margin (#2508).
        var sources: [String: SessionEngine.ExportSource] = [:]
        for margin in margins where hasNote(margin) {
            let source = try sources[margin.sessionId] ?? engine.loadExportSource(sessionId: margin.sessionId)
            sources[margin.sessionId] = source
            let (export, markdown) = try note(for: margin, engine: engine, source: source)
            if !markdown.isEmpty { notes.append((margin, export, markdown)) }
        }
        guard let item = notes.first?.export.item else { return nil }
        let timed = recordedMediaSources.contains(item.mediaSourceType ?? "")
        notes.sort {
            let (lhs, rhs) = (sourceOrder($0.margin, timed: timed), sourceOrder($1.margin, timed: timed))
            return lhs != rhs ? lhs < rhs : ($0.margin.createdAt, $0.margin.id) < ($1.margin.createdAt, $1.margin.id)
        }
        return MarginMarkdownFile(
            fileName: "Margins - \(safeName(item.title)).md",
            markdown: notes.map(\.markdown).joined(separator: separator)
        )
    }

    /// Items whose source is a recording: their Margins follow media time. Every other item is
    /// text, even when narrated, and its Margins follow their character in the text (#572 audit).
    static let recordedMediaSources: Set<String> = [
        AudioSourceType.nativeMediaFile.rawValue, AudioSourceType.browserOwnedMedia.rawValue, AudioSourceType.remoteStream.rawValue,
    ]

    /// Where a Margin sits in the item: media time in a recording, start character in a text,
    /// whether or not narration gave it a media time. A saved percent can be stale (a session
    /// that didn't know the recording's length saved 0%), so it only orders Margins with
    /// neither position, after the rest.
    static func sourceOrder(_ margin: Interjection, timed: Bool) -> (Int, Int) {
        guard margin.targetType == .item else { return (1, margin.roughPercent) }
        guard timed else { return (0, margin.anchor.startChar) }
        return margin.anchor.mediaTimeMs.map { (0, $0) } ?? (1, margin.roughPercent)
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
        let reserved = Set("/\\:*?\"<>|".unicodeScalars)
        var name = ""
        for character in title {
            if character.isWhitespace {
                if !name.hasSuffix(" ") { name.append(" ") }
            } else if character.unicodeScalars.contains(where: { reserved.contains($0) || $0.properties.generalCategory == .control }) {
                // Per scalar: `/` followed by a combining accent is one Character, still a slash.
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
