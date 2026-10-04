import Foundation

/// The shape of "Save Margins to Notes Folder" (#587): a note for each Margin as it's made (the default, as before),
/// or one note per item, written when the listener marks it complete or finishes it.
public enum MarginNotesShape: String, CaseIterable, Sendable {
    case eachMargin = "each_margin"
    case itemOnCompletion = "item_on_completion"

    /// A missing or unknown stored value keeps today's behavior, so a listener who never chose stays on it.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .eachMargin
    }

    public var title: String {
        switch self {
        case .eachMargin: "Send each Margin as it's made"
        case .itemOnCompletion: "Send one note per item when I mark it complete"
        }
    }

    /// Whether a delivery pass writes the per-Margin notes. Per-item mode writes the item note instead.
    public var writesEachMargin: Bool { self == .eachMargin }
}

/// The one-note-per-item Markdown file for the notes folder (#587).
///
/// The note is the session export the listener already uses from the export screen, with YAML properties on top
/// like a Margin note's (#491). Its name and id depend only on the item, so completing an item again rewrites the
/// same file (the notes-folder writer still leaves a note the listener edited alone) instead of adding a copy.
public struct ItemMarginNote: Equatable, Sendable {
    /// The notes-folder writer's key for this note. Never the same as a Margin note's `<session>:<margin>` key.
    public let id: String
    public let fileName: String
    public let markdown: String

    /// The note a delivery pass writes for one item, or nil when it writes none: per-Margin mode, an item not
    /// complete, or one with no Margin that would get a note. `exports` are the item's sessions, oldest first,
    /// built with the notes-folder gatherer's options.
    public static func note(shape: MarginNotesShape, completedAt: Date?, exports: [SessionExport]) -> Self? {
        guard shape == .itemOnCompletion, let completedAt, let item = exports.first?.item else { return nil }
        let withMargins = exports.filter { $0.item.id == item.id && noteworthyMarginCount($0) > 0 }
        let marginCount = withMargins.map(noteworthyMarginCount).reduce(0, +)
        guard marginCount > 0 else { return nil }
        let created = ISO8601DateFormatter().string(from: completedAt)
        let properties = Frontmatter(item: item, created: created, marginCount: marginCount).lines
        let body = withMargins
            .map { SessionExportMarkdownRenderer.render(inListeningOrder($0), includesSessionProgress: false) }
            .joined(separator: "\n")
        return Self(
            id: noteID(itemId: item.id),
            fileName: fileName(title: item.title, itemId: item.id),
            markdown: (properties + [body]).joined(separator: "\n")
        )
    }

    public static func noteID(itemId: String) -> String { "item:" + itemId }

    /// The export with its source Margins in the order they sit in the source, not the order they were recorded:
    /// seeking back to record a Margin must not put it after later ones. Other timeline entries keep their order.
    static func inListeningOrder(_ export: SessionExport) -> SessionExport {
        let margins = Dictionary(uniqueKeysWithValues: export.interjections.map { ($0.id, $0) })
        func sourceMargin(_ entry: ExportTimelineEntry) -> ExportInterjection? {
            guard entry.type == "interjection", let id = entry.interjectionId, let margin = margins[id],
                  margin.targetType == InterjectionTargetType.item.rawValue else { return nil }
            return margin
        }
        let sourceEntries = export.timeline.enumerated()
            .compactMap { index, entry in sourceMargin(entry).map { (index: index, entry: entry, margin: $0) } }
            .sorted { a, b in
                if let aMs = a.margin.mediaTimeMs, let bMs = b.margin.mediaTimeMs, aMs != bMs { return aMs < bMs }
                if a.margin.mediaTimeMs == nil || b.margin.mediaTimeMs == nil, a.margin.roughPercent != b.margin.roughPercent {
                    return a.margin.roughPercent < b.margin.roughPercent
                }
                return a.index < b.index
            }
            .map(\.entry)
        var ordered = export
        ordered.timeline = sourceEntries + export.timeline.filter { sourceMargin($0) == nil }
        return ordered
    }

    /// `<title> — Margins <6 hex>.md`. The digest of the item id keeps two items with the same title apart. The
    /// title loses characters that make a path or that FAT, exFAT and SMB folders refuse, and is cut to 180 UTF-8
    /// bytes so the name stays under the 255-byte limit. The writer should keep the first name it used for a note
    /// id: a title can change after the note is written, and a new name would leave a second copy.
    public static func fileName(title: String, itemId: String) -> String {
        let cleanTitle = sanitizedFileNameComponent(title)
        let tag = String(ListeningEdition.digest(itemId).prefix(6))
        return "\(cleanTitle.isEmpty ? "Untitled" : cleanTitle) — Margins \(tag).md"
    }

    static let maxTitleBytes = 180

    static func sanitizedFileNameComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters).union(.newlines)
        let trim = CharacterSet(charactersIn: ". ")
        var collapsed = value.components(separatedBy: invalid)
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: trim)
        while collapsed.utf8.count > maxTitleBytes { collapsed.removeLast() }
        return collapsed.trimmingCharacters(in: trim)
    }

    /// Margins the per-Margin mode would have written a note for (#171): every spoken one, and written ones with words.
    static func noteworthyMarginCount(_ export: SessionExport) -> Int {
        export.interjections.filter {
            SessionExportMarkdownRenderer.writesMarginNote(captureKind: $0.captureKind, text: $0.transcript)
        }.count
    }

    /// The properties #587 asks for, written the way ``MarginNoteFrontmatter`` writes them.
    struct Frontmatter {
        var title: String
        var source: String?
        var author: String?
        var created: String
        var itemID: String
        var marginCount: Int

        init(item: ExportItem, created: String, marginCount: Int) {
            title = item.title
            // The item's page, not its media file, and never a private feed link.
            source = ShareableLinkPolicy.shareableLink(item.externalReference)
            author = item.author
            self.created = created
            itemID = item.id
            self.marginCount = marginCount
        }

        var lines: [String] {
            var properties: [(String, String)] = [("title", MarginNoteFrontmatter.quoted(title))]
            if let source { properties.append(("source", MarginNoteFrontmatter.quoted(source))) }
            if let author { properties.append(("author", MarginNoteFrontmatter.quoted(author))) }
            properties += [
                ("created", created),
                ("item_id", MarginNoteFrontmatter.quoted(itemID)),
                ("margin_count", String(marginCount)),
                ("tags", "[spoken-margins]"),
            ]
            return ["---"] + properties.map { "\($0.0): \($0.1)" } + ["---", ""]
        }
    }
}
