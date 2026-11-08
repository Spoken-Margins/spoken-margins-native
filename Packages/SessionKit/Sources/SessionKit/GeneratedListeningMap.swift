import Foundation

/// The rule-based chapters of an item that has no map yet (#2256): evenly spaced sentence starts titled by their first
/// words. Pure text work with no engine state and no store, so a caller can run it off the main thread; a 1.1 MB book
/// takes about 0.8 s here, which is why the Prepare Listening Map tap no longer runs it on the main actor.
///
/// The steps and their numbers are what `SessionEngine.generateListeningMap` has always used: 5 to 12 chapters, one
/// per about 900 characters, every one starting at a sentence.
enum GeneratedListeningMap {
    /// The map for `item`, whose chapters are cut from `text`.
    static func make(for item: Item, text: String) -> ListeningMap {
        let starts = chapterStarts(for: text)
        let chapters = starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : text.count
            return Chapter(
                id: "ch-generated-\(String(format: "%02d", index + 1))",
                title: chapterTitle(text: text, start: start, end: end, index: index),
                startChar: start,
                endChar: max(start, end),
                percent: percent(for: start, text: text)
            )
        }
        return ListeningMap(
            id: "map-\(item.id)-generated",
            itemId: item.id,
            overview: ListeningMapOverviewText.appGenerated(title: item.title, chapterCount: chapters.count),
            chapters: chapters
        )
    }

    /// The text the chapters are cut from: the item's own, else its source transcript's segments in time order.
    static func text(for item: Item, transcript: TranscriptTimeline?) -> String {
        if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard let transcript else { return "" }
        return transcript.segments
            .sorted { $0.startMs < $1.startMs }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func chapterStarts(for text: String) -> [Int] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [0] }
        let sentenceStarts = sentenceStartOffsets(in: text)
        guard sentenceStarts.count > 8 else { return sentenceStarts }
        let targetCount = min(12, max(5, Int((Double(text.count) / 900.0).rounded(.up))))
        let stride = max(1, Int((Double(sentenceStarts.count) / Double(targetCount)).rounded(.up)))
        var starts = sentenceStarts.enumerated().compactMap { index, start in
            index % stride == 0 ? start : nil
        }
        if starts.first != 0 { starts.insert(0, at: 0) }
        return Array(starts.prefix(12))
    }

    private static func sentenceStartOffsets(in text: String) -> [Int] {
        let chars = Array(text)
        var starts = [0]
        var index = 0
        while index < chars.count {
            if ".!?".contains(chars[index]) {
                let next = index + 1 + consumeSpaces(chars, from: index + 1)
                if next < chars.count {
                    starts.append(next)
                }
            }
            index += 1
        }
        return Array(NSOrderedSet(array: starts)) as? [Int] ?? starts
    }

    private static func chapterTitle(text: String, start: Int, end: Int, index: Int) -> String {
        let raw = slice(text, start: start, end: min(end, nextSentenceBoundary(after: start, text: text)))
        let words = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .prefix(6)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:,"))
        return words.isEmpty ? "Chapter \(index + 1)" : words
    }

    /// The offset after the sentence that starts at or after `offset`, with the spaces that follow it.
    private static func nextSentenceBoundary(after offset: Int, text: String) -> Int {
        guard offset < text.count else { return text.count }
        let chars = Array(text)
        let boundaryCharacters: Set<Character> = [".", "?", "!"]
        for index in min(offset + 1, chars.count)..<chars.count where boundaryCharacters.contains(chars[index]) {
            return min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
        }
        return text.count
    }

    private static func consumeSpaces(_ chars: [Character], from start: Int) -> Int {
        var count = 0
        var idx = start
        while idx < chars.count, chars[idx].isWhitespace {
            count += 1
            idx += 1
        }
        return count
    }

    private static func slice(_ text: String, start: Int, end: Int) -> String {
        let lower = text.index(text.startIndex, offsetBy: max(0, min(start, text.count)))
        let upper = text.index(text.startIndex, offsetBy: max(0, min(end, text.count)))
        return String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func percent(for charOffset: Int, text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return min(100, max(0, Int((Double(charOffset) / Double(text.count)) * 100)))
    }
}
