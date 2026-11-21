import Foundation

/// What a printed "Table N" or "Figure N" caption looks like, for both kinds in one place (#4588).
///
/// Figures use `PDFFigureCaption`, which the PDF extractor and the figure locator already share; tables use the same
/// rule the extractor's `isTableCaption` has. A body sentence that only mentions a table ("Table 2 shows the…") is not
/// a caption: the number must be followed by punctuation, the line's end or a capital letter.
public enum PDFCaptionPattern {
    /// Whether `line` opens a caption of `kind`. A cheap prefix test comes first, so scanning a long segment's lines
    /// runs the regular expression only on lines that could be captions.
    public static func isCaption(_ line: String, kind: StructuredDocument.Float.Kind) -> Bool {
        switch kind {
        case .figure:
            guard line.hasPrefix("Fig") || line.hasPrefix("FIG") else { return false }
            return PDFFigureCaption.isCaptionStart(line)
        case .table:
            guard line.hasPrefix("Table") || line.hasPrefix("TABLE") else { return false }
            return line.range(of: tablePattern, options: .regularExpression) != nil
        }
    }

    /// The number a caption of `kind` opens with: "3" for "Fig. 3: …", "S1", "IV", "2" for "Table 2.". Nil when the
    /// line is not a caption.
    public static func number(of line: String, kind: StructuredDocument.Float.Kind) -> String? {
        guard isCaption(line, kind: kind) else { return nil }
        let pattern = kind == .figure
            ? #"^(?:Fig(?:ure)?\.?|FIG(?:URE)?\.?)\s*[0-9S]+[0-9.]*"#
            : #"^(?:Table|TABLE)\s+[0-9IVXS]+[0-9.]*"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        var rest = Substring(line[range])
        for word in ["FIGURE", "Figure", "FIG", "Fig", "TABLE", "Table"] where rest.hasPrefix(word) {
            rest = rest.dropFirst(word.count)
            break
        }
        let number = rest.drop { $0 == "." || $0 == " " || $0 == "\t" }
        let trimmed = String(number.reversed().drop { $0 == "." }.reversed())
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let tablePattern = #"^(?:Table|TABLE)\s+[0-9IVXS]+[0-9.]*(?:[.:|]|\s*$|\s+\p{Lu})"#
}

/// A table's or figure's card on the Now tab, placed in the text (#4588).
public struct PDFClipAnchor: Equatable, Sendable {
    public let floatId: String
    public let kind: StructuredDocument.Float.Kind
    /// "Table 2" or "Figure 3"; "Table" or "Figure" when no caption number was found.
    public let numberLabel: String
    /// One-based, as a listener counts pages.
    public let pageNumber: Int
    /// The Character offset the card stands at: the first character of the caption line, else the first character
    /// of the float's own text.
    public let anchor: Int
    /// Width over height of the card's picture, from the float's bounds and an assumed 3:4 page.
    public let aspect: Double
    /// Whether `anchor` is a caption line (true) or the float's own text (false).
    public let hasCaption: Bool
    let pageIndex: Int
    /// The top of the region on its page, bottom-left origin, so a larger value is higher.
    let top: Double
}

/// What `PDFClipAnchors` needs of a structured document: its floats and where its segments are. It holds no copy of the
/// text, and is nil when the document is not the item's text or has no floats, so the Now tab draws no cards.
public struct PDFClipSource: Equatable, Sendable {
    public struct SegmentSpan: Equatable, Sendable {
        public let id: String
        public let role: StructuredDocument.Role
        public let start: Int
        public let end: Int
        let floatId: String?
    }

    public let floats: [StructuredDocument.Float]
    /// In text order.
    public let segments: [SegmentSpan]

    public init?(document: StructuredDocument, text: String) {
        guard !document.floats.isEmpty, document.text == text else { return nil }
        floats = document.floats
        segments = document.segments.enumerated().sorted {
            $0.element.range.start == $1.element.range.start ? $0.offset < $1.offset : $0.element.range.start < $1.element.range.start
        }.map {
            SegmentSpan(id: $0.element.id, role: $0.element.role, start: $0.element.range.start, end: $0.element.range.end,
                        floatId: $0.element.floatId)
        }
    }
}

/// Where each table and figure of a PDF gets its card on the Now tab, found from the document's segment table when Now
/// opens (#4588). Real imports have no `.caption` segments: a caption is a line inside a body or heading segment,
/// usually the first line after a figure's text or the last line before a table, so this reads those lines.
public enum PDFClipAnchors {
    /// How many lines of a neighbouring segment are searched for a caption.
    public static let captionWindow = 6
    /// A page is assumed to be this wide over its height when a card's size is worked out without reading the picture.
    static let assumedPageAspect = 0.75

    /// The anchors in the order their cards are shown: by place in the text, then by page, then top of the page, then id.
    public static func make(text: String, source: PDFClipSource) -> [PDFClipAnchor] {
        var cursor = OffsetCursor(text: text)
        let characterCount = cursor.characterCount
        let segments = source.segments.filter { $0.start >= 0 && $0.end >= $0.start && $0.end <= characterCount }
        // For each own-text segment and kind, the caption lines it could have, nearest side first.
        var options: [String: [CaptionLine]] = [:]
        var numbered: [String: [String: Int]] = [:]

        struct Candidate {
            let float: StructuredDocument.Float
            let own: PDFClipSource.SegmentSpan?
            let key: String?
            var caption: CaptionLine?
        }
        var candidates: [Candidate] = []
        for float in source.floats {
            let ownId = float.textSegmentId ?? segments.first { $0.floatId == float.id }?.id
            let own = ownId.flatMap { id in segments.first { $0.id == id } }
            if let own {
                let key = "\(own.id)|\(float.kind.rawValue)"
                if options[key] == nil {
                    options[key] = captionLines(near: own, kind: float.kind, in: segments, cursor: &cursor)
                }
                candidates.append(Candidate(float: float, own: own, key: key, caption: nil))
            } else if let captionId = float.captionSegmentId, let label = float.label,
                      let segment = segments.first(where: { $0.id == captionId }), canHoldCaption(segment.role),
                      let wanted = label.split(separator: " ").last.map(String.init) {
                let numberKey = "\(segment.id)|\(float.kind.rawValue)"
                if numbered[numberKey] == nil {
                    numbered[numberKey] = captionNumbers(in: segment, kind: float.kind, cursor: &cursor)
                }
                let line = numbered[numberKey]?[wanted].map { CaptionLine(start: $0, number: wanted) }
                candidates.append(Candidate(float: float, own: nil, key: nil, caption: line))
            }
        }

        // Two own-text segments that found one caption line: the nearer one keeps it, and the other tries its next
        // option, until no line has two claimants. Each round moves a segment down its short list, so it ends.
        var choice: [String: Int] = [:]
        var distinct: [String: PDFClipSource.SegmentSpan] = [:]
        for candidate in candidates { if let key = candidate.key, let own = candidate.own { distinct[key] = own } }
        var moved = true
        while moved {
            moved = false
            var owners: [Int: (key: String, distance: Int)] = [:]
            for key in distinct.keys.sorted() {
                guard let own = distinct[key], let list = options[key], let line = list[safe: choice[key] ?? 0] else { continue }
                let distance = line.start < own.start ? own.start - line.start : line.start - own.end
                if let current = owners[line.start] {
                    let wins = distance < current.distance || (distance == current.distance && key < current.key)
                    let loser = wins ? current.key : key
                    if wins { owners[line.start] = (key, distance) }
                    choice[loser, default: 0] += 1
                    moved = true
                    break
                }
                owners[line.start] = (key, distance)
            }
        }
        for index in candidates.indices {
            if let key = candidates[index].key { candidates[index].caption = options[key]?[safe: choice[key] ?? 0] }
        }

        var result: [PDFClipAnchor] = []
        for candidate in candidates {
            let float = candidate.float
            let caption = candidate.caption
            let anchor = caption?.start ?? candidate.own?.start
            guard let anchor, anchor >= 0, anchor <= characterCount else { continue }
            let word = float.kind == .figure ? "Figure" : "Table"
            let number = caption?.number
            result.append(PDFClipAnchor(
                floatId: float.id, kind: float.kind,
                numberLabel: number.map { "\(word) \($0)" } ?? word,
                pageNumber: float.pageIndex + 1, anchor: anchor,
                aspect: float.bounds.height > 0 ? float.bounds.width * assumedPageAspect / float.bounds.height : 1,
                hasCaption: caption != nil, pageIndex: float.pageIndex, top: float.bounds.y + float.bounds.height))
        }
        return result.sorted {
            if $0.anchor != $1.anchor { return $0.anchor < $1.anchor }
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            if $0.top != $1.top { return $0.top > $1.top }
            return $0.floatId < $1.floatId
        }
    }

    // MARK: Caption lines

    struct CaptionLine: Equatable {
        let start: Int
        let number: String?
    }

    /// Roles whose lines can hold a caption.
    private static func canHoldCaption(_ role: StructuredDocument.Role) -> Bool {
        role == .body || role == .heading || role == .caption
    }

    /// Segments the search steps over on the way to a neighbour: what narration skips silently (page furniture,
    /// footnotes, text inside a picture) and the printed text of other tables and figures.
    private static func isStepOver(_ role: StructuredDocument.Role) -> Bool {
        StructuredDocumentSpeech.treatment(for: role) == .skip || role == .table || role == .figureText
    }

    /// The caption lines this own-text segment could have, the preferred side's first, at most one per side.
    private static func captionLines(near own: PDFClipSource.SegmentSpan, kind: StructuredDocument.Float.Kind,
                                     in segments: [PDFClipSource.SegmentSpan], cursor: inout OffsetCursor) -> [CaptionLine] {
        guard let position = segments.firstIndex(where: { $0.id == own.id }) else { return [] }
        func neighbour(step: Int) -> PDFClipSource.SegmentSpan? {
            var index = position + step
            while segments.indices.contains(index) {
                if !isStepOver(segments[index].role) { return segments[index] }
                index += step
            }
            return nil
        }
        var before: CaptionLine?
        if let segment = neighbour(step: -1), canHoldCaption(segment.role) {
            before = lastCaption(in: segment, kind: kind, cursor: &cursor)
        }
        var after: CaptionLine?
        if let segment = neighbour(step: 1), canHoldCaption(segment.role) {
            after = firstCaption(in: segment, kind: kind, cursor: &cursor)
        }
        return (kind == .table ? [before, after] : [after, before]).compactMap { $0 }
    }

    /// The last caption among the segment's last `captionWindow` lines.
    private static func lastCaption(in segment: PDFClipSource.SegmentSpan, kind: StructuredDocument.Float.Kind,
                                    cursor: inout OffsetCursor) -> CaptionLine? {
        let text = cursor.text
        let lower = cursor.index(at: segment.start)
        var lineEnd = cursor.index(at: segment.end)
        var lineEndOffset = segment.end
        for _ in 0..<captionWindow {
            var start = lineEnd
            var startOffset = lineEndOffset
            while start > lower {
                let previous = text.index(before: start)
                if text[previous].isNewline { break }
                start = previous
                startOffset -= 1
            }
            let line = String(text[start..<lineEnd])
            if PDFCaptionPattern.isCaption(line, kind: kind) {
                return CaptionLine(start: startOffset, number: PDFCaptionPattern.number(of: line, kind: kind))
            }
            guard start > lower else { break }
            lineEnd = text.index(before: start)
            lineEndOffset = startOffset - 1
        }
        return nil
    }

    /// The first caption among the segment's first `captionWindow` lines.
    private static func firstCaption(in segment: PDFClipSource.SegmentSpan, kind: StructuredDocument.Float.Kind,
                                     cursor: inout OffsetCursor) -> CaptionLine? {
        let text = cursor.text
        var index = cursor.index(at: segment.start)
        let end = cursor.index(at: segment.end)
        var offset = segment.start
        for _ in 0..<captionWindow {
            guard index < end else { break }
            let lineEnd = text[index..<end].firstIndex(where: \.isNewline) ?? end
            let line = String(text[index..<lineEnd])
            if PDFCaptionPattern.isCaption(line, kind: kind) {
                return CaptionLine(start: offset, number: PDFCaptionPattern.number(of: line, kind: kind))
            }
            guard lineEnd < end else { break }
            offset += text.distance(from: index, to: lineEnd) + 1
            index = text.index(after: lineEnd)
        }
        return nil
    }

    /// For a picture-only figure: every caption number in the caption segment and where its line starts, the first line
    /// winning a repeated number. Read once per segment; the prefix is tested before a line is copied.
    private static func captionNumbers(in segment: PDFClipSource.SegmentSpan, kind: StructuredDocument.Float.Kind,
                                       cursor: inout OffsetCursor) -> [String: Int] {
        let text = cursor.text
        var index = cursor.index(at: segment.start)
        let end = cursor.index(at: segment.end)
        var offset = segment.start
        var result: [String: Int] = [:]
        while index < end {
            let lineEnd = text[index..<end].firstIndex(where: \.isNewline) ?? end
            let slice = text[index..<lineEnd]
            let couldBe = kind == .figure ? (slice.hasPrefix("Fig") || slice.hasPrefix("FIG")) : (slice.hasPrefix("Table") || slice.hasPrefix("TABLE"))
            if couldBe, let number = PDFCaptionPattern.number(of: String(slice), kind: kind), result[number] == nil {
                result[number] = offset
            }
            guard lineEnd < end else { break }
            offset += text.distance(from: index, to: lineEnd) + 1
            index = text.index(after: lineEnd)
        }
        return result
    }

    /// Turns Character offsets into string indices, moving from the last one it gave, so scanning the lines around
    /// each float costs the distance between them and the text is never copied into an array.
    struct OffsetCursor {
        let text: String
        private let count: Int
        var characterCount: Int { count }
        private var offset = 0
        private var position: String.Index

        init(text: String) {
            self.text = text
            count = text.count
            position = text.startIndex
        }

        mutating func index(at target: Int) -> String.Index {
            let clamped = max(0, min(target, count))
            position = text.index(position, offsetBy: clamped - offset)
            offset = clamped
            return position
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The words VoiceOver speaks for a card on the Now tab, shared with the Timeline row's picture (#4588, #3895).
public enum PDFClipLabel {
    /// "Table 2, page 7", "Figure, page 4".
    public static func accessibilityLabel(_ anchor: PDFClipAnchor) -> String {
        "\(anchor.numberLabel), page \(anchor.pageNumber)"
    }

    public static func hint(for kind: StructuredDocument.Float.Kind) -> String {
        "Opens the \(kind == .table ? "table" : "figure") full screen. Playback doesn't change."
    }
}
