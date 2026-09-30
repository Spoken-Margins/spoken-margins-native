import Foundation

/// What an import makes of an I13 document besides its text.
public enum StructuredDocumentImport {
    /// Chapters from the document's headings and its silent outline anchors, with the
    /// same policy v1 PDFs use.
    public static func listeningMap(for document: StructuredDocument, title: String, itemId: String) -> ListeningMap? {
        let characters = Array(document.text)
        let printed = document.segments.filter { $0.role == .heading }.map { segment in
            ParsedMarkdownHeading(
                level: segment.level ?? 2,
                title: String(characters[segment.range.start..<min(segment.range.end, characters.count)])
                    .split(whereSeparator: \.isNewline).joined(separator: " "),
                startChar: segment.range.start
            )
        }
        let anchored = (document.outline ?? []).map {
            ParsedMarkdownHeading(level: $0.level, title: $0.title, startChar: $0.start)
        }
        // Stable, so an anchor keeps its place before a printed heading at the same offset.
        let headings = (anchored + printed).enumerated()
            .sorted { ($0.element.startChar, $0.offset) < ($1.element.startChar, $1.offset) }
            .map(\.element)
        return ParsedObsidianMarkdown(title: title, text: document.text, source: nil, metadata: [:], headings: headings)
            .deterministicListeningMap(itemId: itemId, policy: .canonicalHeadings)
    }
}
