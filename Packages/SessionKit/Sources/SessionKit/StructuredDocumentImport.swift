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
        // The title page is not a "Front Matter" chapter of its own: it starts the first
        // chapter, and an abstract labelled on it is that chapter (#1144).
        let titlePageEnd = titlePageEnd(of: document, characters: characters)
        return ParsedObsidianMarkdown(title: title, text: document.text, source: nil, metadata: [:], headings: headings)
            .deterministicListeningMap(
                itemId: itemId,
                policy: .canonicalHeadings,
                titlePageEnd: titlePageEnd,
                titlePageChapter: abstractLabel(in: document, characters: characters, at: titlePageEnd)
            )
    }

    /// Roles a title page is made of. None is a section of the paper.
    static let titlePageRoles: Set<StructuredDocument.Role> = [.title, .authors, .frontMatter, .pageHeader, .pageFooter]

    /// Where the first text that isn't title-page matter starts, or the end of the text. A
    /// contents page is not title page: it ends there, so it keeps its "Front Matter" chapter.
    static func titlePageEnd(of document: StructuredDocument, characters: [Character]) -> Int {
        for segment in document.segments {
            guard titlePageRoles.contains(segment.role) else { return segment.range.start }
            guard segment.role == .frontMatter else { continue }
            var lineStart = segment.range.start
            let end = min(segment.range.end, characters.count)
            while lineStart < end {
                let lineEnd = characters[lineStart..<end].firstIndex(where: \.isNewline) ?? end
                let key = String(characters[lineStart..<lineEnd]).lowercased().filter(\.isLetter)
                if ["contents", "tableofcontents"].contains(key) { return lineStart }
                lineStart = lineEnd + 1
            }
        }
        return document.text.count
    }

    /// The label of an abstract that starts at `start` on a line of its own ("Abstract",
    /// "ABSTRACT:", "A B S T R A C T", "Summary"), in body type or as a heading, as printed,
    /// without its punctuation. Nil for prose that starts with the word ("Summary statistics
    /// are ...", "Abstract—We study").
    static func abstractLabel(in document: StructuredDocument, characters: [Character], at start: Int) -> String? {
        guard let segment = document.segments.first(where: { $0.range.start == start }),
              [.body, .abstract, .heading].contains(segment.role) else { return nil }
        let firstLine = String(characters[start..<min(segment.range.end, characters.count)].prefix { !$0.isNewline })
            .trimmingCharacters(in: .whitespaces)
        guard firstLine.range(of: #"^(?:abstract|summary|a b s t r a c t)\s*[:.]?$"#,
                              options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return firstLine
            .replacingOccurrences(of: #"\s*[:.]$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "")
    }
}
