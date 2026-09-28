import Foundation

/// What an import makes of an I13 document besides its text.
public enum StructuredDocumentImport {
    /// Chapters from the document's headings, with the same policy v1 PDFs use.
    public static func listeningMap(for document: StructuredDocument, title: String, itemId: String) -> ListeningMap? {
        let characters = Array(document.text)
        let headings = document.segments.filter { $0.role == .heading }.map { segment in
            ParsedMarkdownHeading(
                level: segment.level ?? 2,
                title: String(characters[segment.range.start..<min(segment.range.end, characters.count)])
                    .split(whereSeparator: \.isNewline).joined(separator: " "),
                startChar: segment.range.start
            )
        }
        return ParsedObsidianMarkdown(title: title, text: document.text, source: nil, metadata: [:], headings: headings)
            .deterministicListeningMap(itemId: itemId, policy: .canonicalHeadings)
    }
}
