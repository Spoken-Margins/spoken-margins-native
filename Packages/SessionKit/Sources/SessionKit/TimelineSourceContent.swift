import Foundation

/// Authored text retained by an import, in canonical Character coordinates (#448).
public struct TimelineSourceContent: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let start: Int
        public let text: String
        public let role: StructuredDocument.Role
        public let label: String?
        public let pageIndex: Int?
    }

    public let entries: [Entry]
    public let characterCount: Int
    /// The pictures, embeds and links the import kept, in text order (#2032). They are not entries: the text
    /// they sit in is already one, and Timeline draws a row of their own for each.
    public let elements: [SourceElement]

    public func entry(atCharacter offset: Int) -> Entry? {
        guard offset >= 0, offset <= characterCount else { return nil }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].start <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 ? entries[lower - 1] : nil
    }

    public init(text: String, document: StructuredDocument? = nil, elements: [SourceElement] = []) {
        let characters = Array(text)
        characterCount = characters.count
        self.elements = elements.filter { $0.start >= 0 && $0.start <= characters.count }
        var result: [Entry] = []
        func append(_ range: Range<Int>, role: StructuredDocument.Role = .body,
                    label: String? = nil, pageIndex: Int? = nil) {
            let value = String(characters[range])
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            result.append(Entry(id: String(format: "source.text.%020ld.%020ld", range.lowerBound, result.count),
                                start: range.lowerBound, text: value, role: role, label: label, pageIndex: pageIndex))
        }

        if let document, document.text == text, !document.segments.isEmpty,
           document.segments.allSatisfy({ segment in
               let range = segment.range
               return range.start >= 0 && range.length >= 0 && range.start <= characters.count
                   && range.length <= characters.count - range.start
           }) {
            var coveredEnd = 0
            let segments = document.segments.enumerated().sorted {
                $0.element.range.start == $1.element.range.start
                    ? $0.offset < $1.offset : $0.element.range.start < $1.element.range.start
            }
            for (_, segment) in segments {
                let start = segment.range.start
                let end = start + segment.range.length
                // Incomplete structure must never hide retained source text.
                if coveredEnd < start { append(coveredEnd..<start) }
                let label = document.floats.first {
                    (segment.floatId != nil && $0.id == segment.floatId) || $0.captionSegmentId == segment.id
                }?.label
                let page = segment.pageIndex.flatMap {
                    $0 >= 0 && $0 < document.extraction.pageCount ? $0 : nil
                }
                append(start..<end, role: segment.role, label: label, pageIndex: page)
                coveredEnd = max(coveredEnd, end)
            }
            if coveredEnd < characters.count { append(coveredEnd..<characters.count) }
        } else {
            // Character coordinates preserve grapheme clusters and CRLF. A single
            // line break stays in its paragraph; blank lines (including spaces
            // or tabs) divide paragraphs without consuming the next line's indent.
            var paragraphStart = 0
            var index = 0
            while index < characters.count {
                guard characters[index].isNewline else { index += 1; continue }
                let breakStart = index
                var separatorEnd = index + 1
                var candidate = separatorEnd
                while candidate < characters.count {
                    while candidate < characters.count && characters[candidate].isWhitespace
                            && !characters[candidate].isNewline { candidate += 1 }
                    guard candidate < characters.count && characters[candidate].isNewline else { break }
                    candidate += 1
                    separatorEnd = candidate
                }
                if separatorEnd > breakStart + 1 {
                    append(paragraphStart..<breakStart)
                    paragraphStart = separatorEnd
                }
                index = separatorEnd
            }
            append(paragraphStart..<characters.count)
        }
        entries = result
    }
}
