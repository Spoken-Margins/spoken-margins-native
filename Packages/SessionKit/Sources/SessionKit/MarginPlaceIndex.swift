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

    private let chapterStarts: [Start]
    /// Character offsets at which a paragraph begins, in order. Empty when no text was given.
    private let paragraphStarts: [Int]

    /// - `chapters`: the item's listening-map chapters, in any order.
    /// - `text`: the item's text, only when paragraph numbers are wanted. A paragraph is a run of text between
    ///   line breaks ("\n", the boundary the player skips by), and blank lines don't count.
    /// - `readingUpTo`: the furthest offset a paragraph number will be asked for, so a long text is only read as
    ///   far as it needs to be.
    public init(chapters: [Chapter], text: String? = nil, readingUpTo limit: Int = .max) {
        chapterStarts = chapters
            .compactMap { chapter -> Start? in
                guard let title = MarginPlaceIndex.shortened(chapter.title) else { return nil }
                return Start(startChar: chapter.startChar, title: title)
            }
            .sorted { $0.startChar < $1.startChar }
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
    /// summaries aren't in the source. A Margin with a clock time gets no place here: a publisher-chapter map
    /// numbers its chapters (`startChar` is the chapter's index), so its offsets can't be compared with a
    /// Margin's. Chapter names and paragraph numbers are for Margins at a text position, and the item's text is
    /// only read, and only as far as its last such Margin, when there is one.
    /// - `loadMap`: the item's listening map, nil when it has none or it can't be read.
    public static func places(
        for entries: [MarginCollection.PrivateEntry],
        items: [Item],
        loadMap: (String) -> ListeningMap?
    ) -> [String: Place] {
        let itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Place] = [:]
        for (itemId, group) in Dictionary(grouping: entries.filter { $0.interjection.targetType == .item }, by: \.interjection.itemId) {
            let atText = group.filter { $0.interjection.anchor.mediaTimeMs == nil }
            guard let furthest = atText.map({ $0.interjection.anchor.startChar }).max() else { continue }
            let index = MarginPlaceIndex(
                chapters: loadMap(itemId)?.chapters ?? [], text: itemsById[itemId]?.text, readingUpTo: furthest)
            for entry in atText {
                let offset = entry.interjection.anchor.startChar
                let place = Place(chapterName: index.chapterName(atChar: offset), paragraph: index.paragraph(atChar: offset))
                if place.chapterName != nil || place.paragraph != nil { result[entry.id] = place }
            }
        }
        return result
    }
}
