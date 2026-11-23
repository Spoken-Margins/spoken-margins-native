import Foundation

/// "Find in text" (#5035): finds a typed phrase in an item's stored text.
///
/// Pure and host-testable. Every offset counts Characters of the original stored `Item.text`, the unit
/// `Chapter.startChar` and `StructuredDocument.TextRange` use and the unit playback seeks on, never the normalized
/// copy the comparison runs on. Matching ignores case, curly versus straight quotes, Unicode normalization form,
/// ligatures, runs of whitespace, soft hyphens and a hyphen at a line end inside a word ("hyphen-\nation").
/// It reads no database and changes no stored text.
public enum ItemTextSearch {
    /// Results stop here; `Result.hasMore` says there were more.
    public static let maxMatches = 100
    /// Characters of context kept on each side of a match in `Match.excerpt`.
    public static let excerptContext = 40

    /// Text narration skips and says a notice for ("Table not read."). A match inside it is still returned.
    public struct SkippedSpan: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable { case table, equation }
        public var kind: Kind
        public var start: Int
        public var end: Int
        /// The printed label ("Table 2"), when the document has one.
        public var label: String?

        public init(kind: Kind, start: Int, end: Int, label: String? = nil) {
            self.kind = kind
            self.start = start
            self.end = end
            self.label = label
        }

        /// Spans for the table and equation segments of a structured document, the roles
        /// `StructuredDocumentSpeech` announces and skips. A table takes its float's label when it has one.
        public static func spans(in document: StructuredDocument) -> [SkippedSpan] {
            let labels = Dictionary(document.floats.compactMap { f in f.label.map { (f.id, $0) } },
                                    uniquingKeysWith: { first, _ in first })
            var result: [SkippedSpan] = []
            for segment in document.segments {
                switch segment.role {
                case .table:
                    result.append(SkippedSpan(kind: .table, start: segment.range.start, end: segment.range.end,
                                              label: segment.floatId.flatMap { labels[$0] }))
                case .equation:
                    result.append(SkippedSpan(kind: .equation, start: segment.range.start, end: segment.range.end))
                default:
                    continue
                }
            }
            return result
        }
    }

    public struct Match: Equatable, Sendable {
        /// Original-text Character offsets, `start` inclusive and `end` exclusive.
        public var start: Int
        public var end: Int
        /// One line of context with whitespace runs collapsed to one space.
        public var excerpt: String
        /// The match inside `excerpt`, in Characters (for the bold run).
        public var excerptMatchStart: Int
        public var excerptMatchEnd: Int
        public var excerptTruncatedBefore: Bool
        public var excerptTruncatedAfter: Bool
        /// The chapter the match falls in, when the item has chapters.
        public var chapterId: String?
        public var chapterTitle: String?
        /// Set when the match is inside text narration skips.
        public var notReadAloud: SkippedSpan?
        /// Where playback seeks for this result: the start of the skipped block (where its notice sits) or the match.
        public var playbackOffset: Int { notReadAloud?.start ?? start }

        /// "In Table 2 (not read aloud)", "In an equation (not read aloud)", or nil for text that is read.
        public var notReadAloudDescription: String? {
            guard let span = notReadAloud else { return nil }
            switch span.kind {
            case .table: return "In \(span.label ?? "a table") (not read aloud)"
            case .equation: return "In \(span.label ?? "an equation") (not read aloud)"
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public var matches: [Match]
        /// True when more than `maxMatches` matches exist; `matches` holds the first `maxMatches`.
        public var hasMore: Bool
    }

    public static func search(_ query: String, in text: String, chapters: [Chapter] = [],
                              skipped: [SkippedSpan] = []) -> Result {
        var pattern = normalize(Array(query)).chars
        while pattern.first == " " { pattern.removeFirst() }
        while pattern.last == " " { pattern.removeLast() }
        guard !pattern.isEmpty else { return Result(matches: [], hasMore: false) }

        let original = Array(text)
        let folded = normalize(original)
        let hay = folded.chars
        let origin = folded.origins
        guard hay.count >= pattern.count else { return Result(matches: [], hasMore: false) }

        var matches: [Match] = []
        var hasMore = false
        var i = 0
        let last = hay.count - pattern.count
        while i <= last {
            guard hay[i] == pattern[0], hay[i..<(i + pattern.count)].elementsEqual(pattern) else { i += 1; continue }
            if matches.count == maxMatches { hasMore = true; break }
            let start = origin[i]
            let end = origin[i + pattern.count - 1] + 1
            matches.append(makeMatch(start: start, end: end, original: original, chapters: chapters, skipped: skipped))
            i += pattern.count
        }
        return Result(matches: matches, hasMore: hasMore)
    }

    // MARK: Normalization

    /// The comparison copy of `original`, with the original Character index each comparison character came from.
    private static func normalize(_ original: [Character]) -> (chars: [Character], origins: [Int]) {
        var chars: [Character] = []
        var origins: [Int] = []
        chars.reserveCapacity(original.count)
        origins.reserveCapacity(original.count)
        var lastWasSpace = false
        var i = 0
        while i < original.count {
            let ch = original[i]
            if ch.isWhitespace {
                // A run of whitespace is one space, mapped to the run's first character.
                if !lastWasSpace { chars.append(" "); origins.append(i) }
                lastWasSpace = true
                i += 1
                continue
            }
            lastWasSpace = false
            if ch == "\u{00AD}" { i += 1; continue }
            if ch == "-" || ch == "\u{2010}", i > 0, original[i - 1].isLetter,
               let next = hyphenBreakEnd(after: i, in: original) {
                i = next
                continue
            }
            for folded in fold(ch) {
                chars.append(folded)
                origins.append(i)
            }
            i += 1
        }
        return (chars, origins)
    }

    /// For a hyphen at `index` that ends a line inside a word, the index of the letter that continues it.
    private static func hyphenBreakEnd(after index: Int, in text: [Character]) -> Int? {
        var j = index + 1
        var sawBreak = false
        while j < text.count, text[j].isWhitespace {
            if text[j].isNewline { sawBreak = true }
            j += 1
        }
        return sawBreak && j < text.count && text[j].isLetter ? j : nil
    }

    private static func fold(_ ch: Character) -> [Character] {
        switch ch {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "\u{02BC}": return ["'"]
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": return ["\""]
        default:
            return Array(String(ch).precomposedStringWithCompatibilityMapping.lowercased())
        }
    }

    // MARK: Results

    private static func makeMatch(start: Int, end: Int, original: [Character], chapters: [Chapter],
                                  skipped: [SkippedSpan]) -> Match {
        let from = max(0, start - excerptContext)
        let to = min(original.count, end + excerptContext)

        var excerpt: [Character] = []
        var matchStart = 0
        var matchEnd = 0
        for index in from..<to {
            if index == start { matchStart = excerpt.count }
            if index == end { matchEnd = excerpt.count }
            let ch = original[index]
            if ch.isWhitespace {
                if excerpt.last != " " { excerpt.append(" ") }
            } else {
                excerpt.append(ch)
            }
        }
        if end >= to { matchEnd = excerpt.count }
        let chapter = chapter(at: start, in: chapters)
        let span = skipped.first { $0.start <= start && start < $0.end }
        return Match(start: start, end: end, excerpt: String(excerpt),
                     excerptMatchStart: matchStart, excerptMatchEnd: max(matchEnd, matchStart),
                     excerptTruncatedBefore: from > 0, excerptTruncatedAfter: to < original.count,
                     chapterId: chapter?.id, chapterTitle: chapter?.title, notReadAloud: span)
    }

    private static func chapter(at offset: Int, in chapters: [Chapter]) -> Chapter? {
        if let inside = chapters.first(where: { $0.startChar <= offset && offset < $0.endChar }) { return inside }
        return chapters.filter { $0.startChar <= offset }.max { $0.startChar < $1.startChar }
    }
}
