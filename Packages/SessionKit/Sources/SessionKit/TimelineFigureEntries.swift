import Foundation

extension TimelineSourceContent {
    /// The longest a figure's caption excerpt runs, in Characters from the caption's first character (#4587).
    static let figureExcerptLimit = 300

    /// One entry for each picture-only figure of `document`, at the first character of its caption line, in text order.
    ///
    /// A picture-only figure is a float with a caption and no segment of its own text, so no segment can carry its
    /// picture. The place is the one `PDFClipAnchors` gives Now's card, so both tabs agree. A float with no caption
    /// line found gets no entry, as it gets no card, and a float some segment already names (a document saved before
    /// `textSegmentId` existed) is the printed text's row, not a second one.
    static func figureEntries(text: String, document: StructuredDocument, source: PDFClipSource) -> [Entry] {
        let owned = Set(source.segments.compactMap(\.floatId))
        let floats = Dictionary(source.floats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cursor = PDFClipAnchors.OffsetCursor(text: text)
        var result: [Entry] = []
        for anchor in PDFClipAnchors.make(text: text, source: source) {
            guard let float = floats[anchor.floatId], float.textSegmentId == nil, !owned.contains(float.id) else { continue }
            let segmentEnd = float.captionSegmentId.flatMap { id in source.segments.first { $0.id == id }?.end }
                ?? cursor.characterCount
            let excerpt = captionExcerpt(from: anchor.anchor, segmentEnd: segmentEnd, cursor: &cursor)
            let page = float.pageIndex >= 0 && float.pageIndex < document.extraction.pageCount ? float.pageIndex : nil
            result.append(Entry(
                id: "source.figure.\(float.id)", start: anchor.anchor,
                text: excerpt.isEmpty ? (float.label ?? "") : excerpt,
                role: .caption, label: float.label, pageIndex: page, floatId: float.id, floatKind: float.kind))
        }
        return result
    }

    /// The caption's label and its first sentence, for example "Figure 3. Micrographs of treated cells." (#4587).
    ///
    /// The document stores no caption length, and a caption is a line inside a body segment, so this reads from the
    /// caption's first character until the first of: a sentence end (".", "?" or "!", then closing brackets or quotes,
    /// then a line break, the end of the text, or spaces and a capital letter); a blank line; the end of the caption's
    /// segment; or `figureExcerptLimit` Characters, cut back to the last space. The label's own full stop ("Fig. 2")
    /// and any ".", ":" or "|" after it don't end it. It reads at most `figureExcerptLimit` Characters, so a figure in
    /// a million-character text costs the same as one in a page.
    static func captionExcerpt(from anchor: Int, segmentEnd: Int, cursor: inout PDFClipAnchors.OffsetCursor) -> String {
        let start = max(0, min(anchor, cursor.characterCount))
        let limit = start + figureExcerptLimit
        let windowEnd = min(segmentEnd, limit, cursor.characterCount)
        guard windowEnd > start else { return "" }
        let from = cursor.index(at: start)
        let to = cursor.index(at: windowEnd)
        let characters = Array(cursor.text[from..<to])

        // Where the label ends, then past the punctuation and spaces that follow it.
        let firstLine = String(characters.prefix { !$0.isNewline })
        var index = firstLine.range(of: Self.labelPattern, options: .regularExpression)
            .map { firstLine.distance(from: firstLine.startIndex, to: $0.upperBound) } ?? 0
        while index < characters.count, ".:|".contains(characters[index]) || (characters[index].isWhitespace && !characters[index].isNewline) {
            index += 1
        }

        let closers: Set<Character> = [")", "]", "\"", "’", "”", "'"]
        var end: Int?
        scan: while index < characters.count {
            let character = characters[index]
            if character.isNewline, index + 1 < characters.count, characters[index + 1].isNewline {
                end = index
                break scan
            }
            if character == "." || character == "?" || character == "!" {
                var next = index + 1
                while next < characters.count, closers.contains(characters[next]) { next += 1 }
                if next >= characters.count || characters[next].isNewline {
                    end = next
                    break scan
                }
                if characters[next].isWhitespace {
                    var word = next
                    while word < characters.count, characters[word].isWhitespace, !characters[word].isNewline { word += 1 }
                    if word >= characters.count || characters[word].isNewline || characters[word].isUppercase {
                        end = next
                        break scan
                    }
                }
                index = next
                continue scan
            }
            index += 1
        }
        if end == nil, windowEnd == limit, limit < segmentEnd, limit < cursor.characterCount,
           let space = characters.lastIndex(where: \.isWhitespace), space > 0 {
            // Cut by the Characters limit rather than by the segment: back to the last space.
            end = space
        }
        return String(characters[0..<(end ?? characters.count)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let labelPattern = #"^(?:Fig(?:ure)?\.?|FIG(?:URE)?\.?)\s*[0-9S]+[0-9.]*"#
}
