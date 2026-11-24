import Foundation

/// One footnote that can be heard where it is cited (#3777): a `[^label]` citation in the body, paired
/// with the `[^label]: text` definition that explains it. Every offset counts characters in the text
/// that was searched (the stored article text), the same unit as `ParsedObsidianMarkdown.text.count`
/// and a chapter's `startChar`, so nothing here is shifted by speech normalisation.
public struct FootnoteAnchor: Equatable, Sendable {
    /// The label as the definition writes it, in canonical (NFC) form: `1`, `a`, `note-1`.
    public let label: String
    /// The first citation of this note, `[^label]` included. The note is read after this citation's sentence.
    public let citationRange: Range<Int>
    /// Later citations of the same note. The note was already heard at the first one, so these stay silent.
    public let laterCitationRanges: [Range<Int>]
    /// The whole definition, from its `[` to its last character.
    public let definitionRange: Range<Int>
    /// The note's words, ready to read: its lines joined with single spaces, without a leading back-link
    /// arrow or the label repeated, and without a trailing back-link arrow.
    public let text: String

    /// Every citation of this note, first one first.
    public var citationRanges: [Range<Int>] { [citationRange] + laterCitationRanges }
}

/// Pairs the footnote citations of an article with their definitions.
///
/// A note is matched only when it is certain: a label with exactly one definition and at least one
/// citation ahead of it. Everything else is left unmatched, so the narrator keeps today's behaviour for it
/// (it says "footnote 3" at the marker and the note is read in the closing notes chapter). A wrong anchor
/// would read the wrong words at the wrong place, so the finder never guesses.
///
/// Matching rules (the Design on #3777):
/// 1. A definition is `[^label]:` at the start of a line. Its text runs to the next definition, the next
///    heading or the end of the text when it is inside the closing notes section. A definition elsewhere
///    keeps its own paragraph (the lines up to the next blank line) and any indented lines after a blank
///    one, so a later paragraph is never swallowed. The import trims every line, so a continuation is
///    told apart by having no blank line before it, not by its indentation.
/// 2. A citation is `[^label]` anywhere else, outside the definitions' own words. The import also strips
///    code spans and backslash escapes before the text is stored, so a `[^3]` that was code or escaped is
///    indistinguishable here; it still needs a matching definition to become an anchor.
/// 3. A label matches when it has exactly one definition and a citation before that definition and before
///    the notes section starts (stricter than "before the notes section" for a definition that sits
///    mid-article: a citation after it never counts).
/// 4. The note belongs to the first citation. Later citations are reported separately and stay silent.
/// 5. A label that is cited but not defined, defined but not cited, or defined twice is not matched.
///
/// PDFs carry no `[^n]` markers (their footnotes are skipped where they sit), so they match nothing.
public enum FootnoteAnchors {
    /// The matched notes, in the order of their first citations.
    ///
    /// - Parameters:
    ///   - text: the stored article text.
    ///   - notesStartChar: where the closing notes section starts (`ParsedObsidianMarkdown.notesStartChar`),
    ///     when known. Without it, "before the notes section" means "before this note's definition".
    ///   - headingStarts: the character offsets where headings start, when known. A definition inside the
    ///     notes section ends at the next one.
    public static func find(
        in text: String,
        notesStartChar: Int? = nil,
        headingStarts: [Int] = []
    ) -> [FootnoteAnchor] {
        guard text.contains("[^") else { return [] }
        let characters = Array(text)
        let lines = splitLines(characters)
        let definitions = findDefinitions(lines, in: characters)
        guard !definitions.isEmpty else { return [] }

        let extents = definitionExtents(
            definitions, lines: lines, notesStartChar: notesStartChar,
            headingStarts: headingStarts.sorted(), characters: characters)
        let citations = findCitations(lines, in: characters, skipping: extents)
        guard !citations.isEmpty else { return [] }

        var definitionsByLabel: [String: [Int]] = [:]
        for (index, definition) in definitions.enumerated() { definitionsByLabel[definition.label, default: []].append(index) }
        let citationsByLabel = Dictionary(grouping: citations, by: \.label)

        var anchors: [FootnoteAnchor] = []
        for (label, indexes) in definitionsByLabel {
            guard indexes.count == 1, let cited = citationsByLabel[label] else { continue }
            let definition = definitions[indexes[0]]
            let extent = extents[indexes[0]]
            let qualifying = cited
                .filter { citation in
                    citation.range.lowerBound < definition.lineStart
                        && notesStartChar.map { citation.range.lowerBound < $0 } ?? true
                }
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
            guard let first = qualifying.first else { continue }
            let cleaned = readableText(extent.lines, label: label)
            guard !cleaned.isEmpty else { continue }
            anchors.append(FootnoteAnchor(
                label: label,
                citationRange: first.range,
                laterCitationRanges: qualifying.dropFirst().map(\.range),
                definitionRange: definition.lineStart..<extent.end,
                text: cleaned))
        }
        return anchors.sorted { $0.citationRange.lowerBound < $1.citationRange.lowerBound }
    }

    // MARK: - Lines

    private struct Line {
        /// Offset of the line's first character.
        var start: Int
        /// Offset just past the line's last character, before its line break.
        var end: Int
    }

    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    private static func splitLines(_ characters: [Character]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        for index in characters.indices where isLineBreak(characters[index]) {
            lines.append(Line(start: start, end: index))
            start = index + 1
        }
        lines.append(Line(start: start, end: characters.count))
        return lines
    }

    // MARK: - Scanning

    private struct Definition {
        var label: String
        var lineIndex: Int
        var lineStart: Int
        /// Offset of the first character after `]:`.
        var textStart: Int
    }

    private struct Citation {
        var label: String
        var range: Range<Int>
    }

    private static func findDefinitions(_ lines: [Line], in characters: [Character]) -> [Definition] {
        var definitions: [Definition] = []
        var inFence = false
        for (lineIndex, line) in lines.enumerated() {
            if isFence(line, in: characters) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let marker = marker(at: line.start, upTo: line.end, in: characters),
               marker.end < line.end, characters[marker.end] == ":" {
                definitions.append(Definition(
                    label: marker.label, lineIndex: lineIndex, lineStart: line.start, textStart: marker.end + 1))
            }
        }
        return definitions
    }

    /// Citations in the lines no definition owns and outside fenced blocks.
    private static func findCitations(
        _ lines: [Line], in characters: [Character], skipping extents: [Extent]
    ) -> [Citation] {
        var owned = Set<Int>()
        for extent in extents { owned.formUnion(extent.lineIndexes) }
        var citations: [Citation] = []
        var inFence = false
        for (lineIndex, line) in lines.enumerated() {
            if isFence(line, in: characters) {
                inFence.toggle()
                continue
            }
            if inFence || owned.contains(lineIndex) { continue }
            var index = line.start
            while index < line.end {
                if characters[index] == "[", let found = marker(at: index, upTo: line.end, in: characters) {
                    citations.append(Citation(label: found.label, range: index..<found.end))
                    index = found.end
                } else {
                    index += 1
                }
            }
        }
        return citations
    }

    private static func isFence(_ line: Line, in characters: [Character]) -> Bool {
        var index = line.start
        while index < line.end, characters[index] == " " || characters[index] == "\t" { index += 1 }
        guard line.end - index >= 3 else { return false }
        let first = characters[index]
        guard first == "`" || first == "~" else { return false }
        return characters[index + 1] == first && characters[index + 2] == first
    }

    /// A `[^label]` at `index`: its label (canonical form) and the offset just past the `]`.
    private static func marker(at index: Int, upTo limit: Int, in characters: [Character]) -> (label: String, end: Int)? {
        guard index + 2 < limit, characters[index] == "[", characters[index + 1] == "^" else { return nil }
        var cursor = index + 2
        while cursor < limit {
            let character = characters[cursor]
            if character == "]" { break }
            if character == "[" || character.isWhitespace { return nil }
            cursor += 1
        }
        guard cursor < limit, cursor > index + 2 else { return nil }
        let label = String(characters[(index + 2)..<cursor]).precomposedStringWithCanonicalMapping
        return (label, cursor + 1)
    }

    // MARK: - Definitions

    private struct Extent {
        /// The definition's line texts, the first starting after `]:`.
        var lines: [String]
        /// The indexes of the lines the definition owns.
        var lineIndexes: Range<Int>
        /// Offset just past its last non-blank character.
        var end: Int
    }

    /// Every definition's extent, in one pass: each stops at the next definition, the next heading or the end.
    private static func definitionExtents(
        _ definitions: [Definition],
        lines: [Line],
        notesStartChar: Int?,
        headingStarts: [Int],
        characters: [Character]
    ) -> [Extent] {
        var extents: [Extent] = []
        extents.reserveCapacity(definitions.count)
        var headingCursor = 0
        for (position, definition) in definitions.enumerated() {
            while headingCursor < headingStarts.count, headingStarts[headingCursor] <= definition.lineStart { headingCursor += 1 }
            let nextDefinition = position + 1 < definitions.count ? definitions[position + 1].lineStart : nil
            let nextHeading = headingCursor < headingStarts.count ? headingStarts[headingCursor] : nil
            let boundary = [nextDefinition, nextHeading].compactMap { $0 }.min() ?? characters.count
            let inNotesSection = notesStartChar.map { definition.lineStart >= $0 } ?? false

            var texts = [String(characters[definition.textStart..<lines[definition.lineIndex].end])]
            var end = lines[definition.lineIndex].end
            var lastLine = definition.lineIndex
            var index = definition.lineIndex + 1
            var afterBlank = false
            while index < lines.count, lines[index].start < boundary {
                let line = lines[index]
                let content = String(characters[line.start..<line.end])
                if content.allSatisfy(\.isWhitespace) {
                    afterBlank = true
                } else if inNotesSection || !afterBlank || content.first?.isWhitespace == true {
                    // In the notes section every line up to the next definition belongs to the note. Elsewhere
                    // a line continues the note when no blank line came before it, or when it is indented.
                    texts.append(content)
                    end = line.end
                    lastLine = index
                    afterBlank = false
                } else {
                    break
                }
                index += 1
            }
            // Trailing whitespace on the last line is not part of the definition.
            while end > definition.textStart, characters[end - 1].isWhitespace { end -= 1 }
            extents.append(Extent(
                lines: texts, lineIndexes: definition.lineIndex..<(lastLine + 1), end: max(end, definition.textStart)))
        }
        return extents
    }

    /// Arrows that jump from a note back to its citation, with or without a variation selector.
    private static let backLinkScalars: Set<UInt32> = [0x21A9, 0x2191, 0x2934, 0x2B06, 0x21B5, 0xFE0E, 0xFE0F]

    private static func isBackLink(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { backLinkScalars.contains($0.value) }
    }

    /// The words a listener should hear for a note.
    private static func readableText(_ lines: [String], label: String) -> String {
        var text = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Back-link arrows that jump from the note back to its citation.
        while let first = text.first, isBackLink(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let last = text.last, isBackLink(last) {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The label written again ahead of the words: "3. Smith 2020", "3) Smith 2020", "[^3] Smith 2020".
        for lead in ["[^\(label)]", label] where text.hasPrefix(lead) {
            let rest = text.dropFirst(lead.count)
            if lead.hasPrefix("[") {
                text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if label.count <= 3, label.allSatisfy({ $0.isNumber }) || label.count == 1,
                      let punctuation = rest.first, ".)".contains(punctuation) {
                let afterPunctuation = rest.dropFirst()
                if afterPunctuation.first?.isWhitespace == true {
                    text = afterPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            break
        }
        return text
    }
}

extension FootnoteAnchors {
    /// What a reader on screen shows in place of each footnote marker (#5109), in text order, never overlapping.
    ///
    /// Shown text is not heard text, so this is looser than `find`, which pairs a note only when it is certain:
    /// - every definition line's `[^label]:` reads "Footnote label:", the words the Timeline's row uses;
    /// - a `[^label]` elsewhere (a definition's own words included) reads as a small marker, but only when some line
    ///   defines that label. One with no definition is left as it is: it may not be a footnote at all.
    /// Markers inside fenced code blocks are left as they are. Offsets count characters in `text`.
    static func displayEdits(in text: String) -> [FootnoteDisplayText.Edit] {
        guard text.contains("[^") else { return [] }
        let characters = Array(text)
        let lines = splitLines(characters)
        let definitions = findDefinitions(lines, in: characters)
        guard !definitions.isEmpty else { return [] }
        let defined = Set(definitions.map(\.label))
        var definitionAt: [Int: Definition] = [:]
        for definition in definitions { definitionAt[definition.lineIndex] = definition }

        var edits: [FootnoteDisplayText.Edit] = []
        var inFence = false
        for (lineIndex, line) in lines.enumerated() {
            if isFence(line, in: characters) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            var index = line.start
            if let definition = definitionAt[lineIndex] {
                edits.append(.init(range: line.start..<definition.textStart, replacement: "Footnote \(definition.label):"))
                index = definition.textStart
            }
            while index < line.end {
                if characters[index] == "[", let found = marker(at: index, upTo: line.end, in: characters) {
                    if defined.contains(found.label) {
                        edits.append(.init(range: index..<found.end, replacement: FootnoteDisplayText.citationMark(found.label)))
                    }
                    index = found.end
                } else {
                    index += 1
                }
            }
        }
        return edits
    }
}
