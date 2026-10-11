import Foundation

/// Where in an item a Margin was made, in the words a listener uses: the chapter it falls in and, for text, the
/// paragraph number (#777). Built once per item from what is already stored, so a row costs a binary search.
public struct MarginPlaceIndex: Equatable, Sendable {
    /// A chapter name longer than this is cut, so the row's second line stays on one line.
    public static let maximumNameCharacters = 28

    private struct Start: Equatable, Sendable {
        let startChar: Int
        let title: String
    }

    private struct MediaStart: Equatable, Sendable {
        let startMs: Int
        let title: String
    }

    private let chapterStarts: [Start]
    /// Where the item's own chapters start in its audio, in order. Empty for text.
    private let mediaChapterStarts: [MediaStart]
    /// Character offsets at which a paragraph begins, in order. Empty when no text was given.
    private let paragraphStarts: [Int]

    /// - `chapters`: the item's listening-map chapters, in any order.
    /// - `mediaChapters`: the chapters of a podcast or audiobook with their start times, in any order. Chapters the
    ///   app made up from the transcript are left out: only the publisher's own chapters name a place (the same rule
    ///   the player's header uses).
    /// - `text`: the item's text, only when paragraph numbers are wanted. A paragraph is a run of text between
    ///   line breaks ("\n", the boundary the player skips by), and blank lines don't count.
    /// - `readingUpTo`: the furthest offset a paragraph number will be asked for, so a long text is only read as
    ///   far as it needs to be.
    public init(
        chapters: [Chapter],
        mediaChapters: [MediaTimelineChapter] = [],
        text: String? = nil,
        readingUpTo limit: Int = .max
    ) {
        chapterStarts = chapters
            .compactMap { chapter -> Start? in
                guard let title = MarginPlaceIndex.shortened(chapter.title) else { return nil }
                return Start(startChar: chapter.startChar, title: title)
            }
            .sorted { $0.startChar < $1.startChar }
        mediaChapterStarts = mediaChapters
            .filter { !MarginPlaceIndex.isSynthetic($0) && $0.startMs >= 0 }
            .compactMap { chapter -> MediaStart? in
                guard let title = MarginPlaceIndex.shortened(chapter.title) else { return nil }
                return MediaStart(startMs: chapter.startMs, title: title)
            }
            .sorted { $0.startMs < $1.startMs }
        paragraphStarts = text.map { MarginPlaceIndex.computeParagraphStarts(in: $0, upTo: limit) } ?? []
    }

    /// The chapter the offset falls in: the last one that starts at or before it. nil before the first chapter
    /// starts, and when the item has none.
    public func chapterName(atChar offset: Int) -> String? {
        var low = 0, high = chapterStarts.count
        while low < high {
            let middle = (low + high) / 2
            if chapterStarts[middle].startChar <= offset { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : chapterStarts[low - 1].title
    }

    /// The chapter of a podcast or audiobook that the time falls in: the last one that starts at or before it. nil
    /// before the first chapter starts, and when the item has none.
    public func chapterName(atMediaTimeMs time: Int) -> String? {
        var low = 0, high = mediaChapterStarts.count
        while low < high {
            let middle = (low + high) / 2
            if mediaChapterStarts[middle].startMs <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : mediaChapterStarts[low - 1].title
    }

    /// 1-based paragraph number, nil when no text was given or the offset is negative. An offset past the end
    /// belongs to the last paragraph.
    public func paragraph(atChar offset: Int) -> Int? {
        guard offset >= 0, !paragraphStarts.isEmpty else { return nil }
        var low = 0, high = paragraphStarts.count
        while low < high {
            let middle = (low + high) / 2
            if paragraphStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }

    fileprivate static func computeParagraphStarts(in text: String, upTo limit: Int) -> [Int] {
        var starts: [Int] = []
        var afterBreak = true
        for (offset, character) in text.enumerated() {
            if offset > limit { break }
            if character == "\n" {
                afterBreak = true
            } else if !isBlank(character) {
                if afterBreak { starts.append(offset) }
                afterBreak = false
            }
        }
        return starts
    }

    private static func isSynthetic(_ chapter: MediaTimelineChapter) -> Bool {
        chapter.id.hasPrefix("ch-transcript-") || chapter.id.contains("-ch-transcript-")
    }

    private static func isBlank(_ character: Character) -> Bool {
        if let ascii = character.asciiValue { return ascii == 32 || (9...13).contains(ascii) }
        return character.isWhitespace
    }

    private static func shortened(_ title: String) -> String? {
        let words = title.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let single = words.joined(separator: " ")
        guard single.count > maximumNameCharacters else { return single }
        return String(single.prefix(maximumNameCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The place of each of an item's Margins that the Margins tab shows (#777).
public enum MarginPlaces {
    public struct Place: Equatable, Sendable {
        public let chapterName: String?
        public let paragraph: Int?
    }

    /// Keyed by `MarginCollection.PrivateEntry.id`. Only Margins on the item itself have a place; responses and
    /// summaries aren't in the source.
    /// - A Margin at a text position gets its chapter name and paragraph number. The item's text is only read, and
    ///   only as far as its last such Margin, when there is one.
    /// - A Margin with a clock time gets the name of the publisher chapter its time falls in, from `loadMediaChapters`.
    ///   It never looks at `loadMap`: a publisher-chapter map numbers its chapters (`startChar` is the chapter's
    ///   index), so its offsets can't be compared with a Margin's.
    /// - `loadMap`: the item's listening map, nil when it has none or it can't be read.
    /// - `loadMediaChapters`: the item's chapters with their start times, empty when it has none. Asked only for items
    ///   that have a Margin with a clock time.
    public static func places(
        for entries: [MarginCollection.PrivateEntry],
        items: [Item],
        loadMap: (String) -> ListeningMap?,
        loadMediaChapters: (String) -> [MediaTimelineChapter] = { _ in [] }
    ) -> [String: Place] {
        let itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Place] = [:]
        for (itemId, group) in Dictionary(grouping: entries.filter { $0.interjection.targetType == .item }, by: \.interjection.itemId) {
            let atText = group.filter { $0.interjection.anchor.mediaTimeMs == nil }
            if let furthest = atText.map({ $0.interjection.anchor.startChar }).max() {
                let index = MarginPlaceIndex(
                    chapters: loadMap(itemId)?.chapters ?? [], text: itemsById[itemId]?.text, readingUpTo: furthest)
                for entry in atText {
                    let offset = entry.interjection.anchor.startChar
                    let place = Place(chapterName: index.chapterName(atChar: offset), paragraph: index.paragraph(atChar: offset))
                    if place.chapterName != nil || place.paragraph != nil { result[entry.id] = place }
                }
            }
            let atTime = group.filter { $0.interjection.anchor.mediaTimeMs != nil }
            guard !atTime.isEmpty else { continue }
            let index = MarginPlaceIndex(chapters: [], mediaChapters: loadMediaChapters(itemId))
            for entry in atTime {
                guard let time = entry.interjection.anchor.mediaTimeMs,
                      let name = index.chapterName(atMediaTimeMs: time) else { continue }
                result[entry.id] = Place(chapterName: name, paragraph: nil)
            }
        }
        return result
    }
}
