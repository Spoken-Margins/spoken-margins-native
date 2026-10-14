import Foundation

/// The live passage the Now view shows for an article or PDF (#451).
///
/// A few sentences of the item's stored text around the playhead, the current one lit, with a diamond for each
/// Margin at the sentence it sits on. The view only draws what `window` returns; it is meant to be called when
/// the current sentence changes, not on every clock tick.
///
/// All offsets count Characters in the item's stored text, the same unit as `Chapter.startChar` and a playback
/// snapshot's `currentTextStart`, so a Margin's text anchor lands on the same sentence the reader sheet shows.
public enum PlaybackLivePassage {
    /// Sentences shown before the current one.
    public static let defaultSentencesBefore = 1
    /// Sentences shown after the current one.
    public static let defaultSentencesAfter = 3
    /// A run of text with no sentence end (a PDF line, a list) is cut at a space once it passes this many
    /// Characters, so one "sentence" can't fill the screen.
    public static let maxSentenceLength = 320

    /// A Margin anchored to the text at a Character offset.
    public struct Margin: Sendable, Equatable {
        public let id: String
        public let offset: Int
        public let origin: PlaybackNowMargins.Origin

        public init(id: String, offset: Int, origin: PlaybackNowMargins.Origin) {
            self.id = id
            self.offset = offset
            self.origin = origin
        }
    }

    /// The diamond drawn in the gutter beside a sentence.
    public struct Diamond: Sendable, Equatable, Identifiable {
        public let id: String
        public let origin: PlaybackNowMargins.Origin

        public init(id: String, origin: PlaybackNowMargins.Origin) {
            self.id = id
            self.origin = origin
        }
    }

    public struct Sentence: Sendable, Equatable, Identifiable {
        /// The sentence's first Character offset, which is unique within a window.
        public var id: Int { start }
        public let start: Int
        /// One past the last Character of the sentence text, trailing space excluded.
        public let end: Int
        public let text: String
        public let isCurrent: Bool
        /// Margins anchored in this sentence, in text order (ties by id).
        public let diamonds: [Diamond]

        public init(start: Int, end: Int, text: String, isCurrent: Bool, diamonds: [Diamond]) {
            self.start = start
            self.end = end
            self.text = text
            self.isCurrent = isCurrent
            self.diamonds = diamonds
        }
    }

    public struct Window: Sendable, Equatable {
        /// The chapter the passage sits in; nil when the item has no chapters.
        public let chapterTitle: String?
        /// The sentences to show, in reading order. Empty when the item has no text.
        public let sentences: [Sentence]
        /// Index in `sentences` of the lit sentence; nil only when there are no sentences.
        public let currentIndex: Int?
        /// The chapter has text before the first shown sentence.
        public let hasEarlier: Bool
        /// The chapter has text after the last shown sentence.
        public let hasLater: Bool

        public init(chapterTitle: String?, sentences: [Sentence], currentIndex: Int?, hasEarlier: Bool, hasLater: Bool) {
            self.chapterTitle = chapterTitle
            self.sentences = sentences
            self.currentIndex = currentIndex
            self.hasEarlier = hasEarlier
            self.hasLater = hasLater
        }

        public static let empty = Window(chapterTitle: nil, sentences: [], currentIndex: nil, hasEarlier: false, hasLater: false)
    }

    /// The window around `offset`.
    ///
    /// - The window never crosses a chapter boundary. It stays in the chapter the reader sheet would open at for
    ///   this offset (the chapter that contains it, else the last one starting before it, else the first), so
    ///   the title above the passage always belongs to the text under it.
    /// - The lit sentence is the one containing `offset`. An offset before the text lights the first sentence and
    ///   one past the end lights the last. Trailing space belongs to the sentence before it.
    /// - A sentence ends at `.`, `!` or `?` (closing quotes and brackets included) followed by space, and at a
    ///   paragraph break (two or more line breaks). A single line break is just space, so hard-wrapped lines
    ///   stay in one sentence. A stop is not an end after a lowercase-led continuation ("e.g. the"), a
    ///   single-letter initial ("J. Smith") or a common title or abbreviation ("Dr. Smith").
    /// - A Margin's diamond sits on the sentence containing its offset. Margins outside the shown sentences are
    ///   left out.
    public static func window(
        text: String,
        chapters: [Chapter] = [],
        offset: Int,
        margins: [Margin] = [],
        sentencesBefore: Int = defaultSentencesBefore,
        sentencesAfter: Int = defaultSentencesAfter
    ) -> Window {
        var index = Index(text: text, chapters: chapters)
        index.update(offset: offset, margins: margins, sentencesBefore: sentencesBefore, sentencesAfter: sentencesAfter)
        return index.window
    }

    /// A selectable chapter and its current sentence in UIKit/Foundation UTF-16 coordinates.
    public struct Reader: Equatable, Sendable {
        public let chapterTitle: String?
        public let text: String
        public let currentSentenceRange: NSRange?
    }

    /// Immutable parsed chapter. Reusing its identity proves playback ticks do not split the text again.
    public final class IndexedChapter: Sendable {
        public let title: String?
        public let bounds: Range<Int>
        private let characters: [Character]
        fileprivate let ranges: [Range<Int>]

        fileprivate init(title: String?, bounds: Range<Int>, characters: [Character]) {
            self.title = title
            self.bounds = bounds
            self.characters = characters
            ranges = sentenceRanges(in: characters, within: bounds)
        }

        public func reader(at offset: Int) -> Reader {
            let text = String(characters[bounds])
            guard !ranges.isEmpty else { return Reader(chapterTitle: title, text: text, currentSentenceRange: nil) }
            let range = trimmedEnd(of: ranges[sentenceIndex(containing: offset, in: ranges)], in: characters)
            let start = text.index(text.startIndex, offsetBy: range.lowerBound - bounds.lowerBound)
            let end = text.index(text.startIndex, offsetBy: range.upperBound - bounds.lowerBound)
            return Reader(chapterTitle: title, text: text, currentSentenceRange: NSRange(start..<end, in: text))
        }

        fileprivate func window(current: Int, margins: [Margin], before: Int, after: Int) -> Window {
            guard !ranges.isEmpty else {
                return Window(chapterTitle: title, sentences: [], currentIndex: nil, hasEarlier: false, hasLater: false)
            }
            let first = max(0, current - before)
            let last = min(ranges.count - 1, current + after)
            let shown = (first...last).map { index -> Sentence in
                let anchored = margins
                    .filter { isInChapter($0.offset, bounds: bounds, textLength: characters.count)
                        && sentenceIndex(containing: $0.offset, in: ranges) == index }
                    .sorted { $0.offset == $1.offset ? $0.id < $1.id : $0.offset < $1.offset }
                let trimmed = trimmedEnd(of: ranges[index], in: characters)
                return Sentence(start: trimmed.lowerBound, end: trimmed.upperBound, text: String(characters[trimmed]),
                                isCurrent: index == current,
                                diamonds: anchored.map { Diamond(id: $0.id, origin: $0.origin) })
            }
            return Window(chapterTitle: title, sentences: shown, currentIndex: current - first,
                          hasEarlier: first > 0, hasLater: last < ranges.count - 1)
        }
    }

    /// View-owned index: parse a chapter once, and rebuild only the small window when its inputs change.
    /// Create a new index when the source text or chapters change. No playback state is owned here.
    public struct Index: Sendable {
        private struct ChapterKey: Hashable, Sendable {
            let title: String?
            let bounds: Range<Int>
        }
        private struct Selection: Equatable, Sendable {
            let chapter: ChapterKey
            let sentence: Int
            let margins: [Margin]
            let before: Int
            let after: Int
        }
        private let characters: [Character]
        private let chapters: [Chapter]
        private var cache: [ChapterKey: IndexedChapter] = [:]
        private var selection: Selection?
        public private(set) var chapter: IndexedChapter?
        public private(set) var window: Window = .empty
        public var characterCount: Int { characters.count }

        public init(text: String, chapters: [Chapter] = []) {
            characters = Array(text)
            self.chapters = chapters
        }

        /// Returns whether the displayed window changed. Whitespace belongs to the preceding sentence,
        /// even though the displayed sentence excludes it; offsets cannot be memoized using visible bounds.
        @discardableResult
        public mutating func update(offset: Int, margins: [Margin] = [],
                                    sentencesBefore: Int = defaultSentencesBefore,
                                    sentencesAfter: Int = defaultSentencesAfter) -> Bool {
            guard !characters.isEmpty else { return false }
            let span = PlaybackLivePassage.chapter(at: offset, in: chapters, textLength: characters.count)
            let key = ChapterKey(title: span?.title, bounds: span?.range ?? 0..<characters.count)
            let parsed = cache[key] ?? IndexedChapter(title: key.title, bounds: key.bounds, characters: characters)
            cache[key] = parsed
            chapter = parsed
            let current = sentenceIndex(containing: offset, in: parsed.ranges)
            let next = Selection(chapter: key, sentence: current, margins: margins,
                                 before: max(0, sentencesBefore), after: max(0, sentencesAfter))
            guard next != selection else { return false }
            selection = next
            let value = parsed.window(current: current, margins: margins, before: next.before, after: next.after)
            guard value != window else { return false }
            window = value
            return true
        }
    }

    // MARK: Chapter

    private struct ChapterSpan {
        let title: String
        let range: Range<Int>
    }

    /// Mirrors the reader sheet's choice so tapping the passage opens the chapter it was showing.
    private static func chapter(at offset: Int, in chapters: [Chapter], textLength: Int) -> ChapterSpan? {
        guard !chapters.isEmpty else { return nil }
        let clamped = max(0, min(offset, textLength))
        let picked = chapters.first(where: { clamped >= $0.startChar && clamped < $0.endChar })
            ?? chapters.last(where: { $0.startChar <= clamped })
            ?? chapters.first
        guard let picked else { return nil }
        let start = max(0, min(picked.startChar, textLength))
        let end = max(start, min(picked.endChar, textLength))
        return ChapterSpan(title: picked.title, range: start..<end)
    }

    // MARK: Sentences

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’", "»"]
    /// Titles and labels that are followed by a name or number, so a stop after them never ends a sentence.
    private static let leadingAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "gen", "gov", "sen", "rep", "rev", "col", "capt",
        "sgt", "lt", "mt", "cf"
    ]
    /// Labels and months that are followed by a number ("No. 5", "p. 12", "Mar. 5"), so a stop after them only
    /// continues the sentence before a digit. "I said no. Then left." still ends after "no".
    private static let numberedAbbreviations: Set<String> = [
        "no", "fig", "eq", "p", "pp", "vol", "ch", "sec", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec"
    ]
    /// Abbreviations that can also close a sentence: a stop after them only continues it before a lowercase word.
    private static let trailingAbbreviations: Set<String> = ["etc", "inc", "ltd", "co", "approx", "dept", "est", "ft", "al"]

    /// Contiguous, non-overlapping ranges covering `bounds` from the first non-space Character. Each runs from a
    /// sentence's first Character up to the next sentence's first Character, so trailing space belongs to the
    /// sentence before it. Space at the very start of `bounds` goes to the first sentence.
    private static func sentenceRanges(in chars: [Character], within bounds: Range<Int>) -> [Range<Int>] {
        var starts: [Int] = []
        var index = bounds.lowerBound
        while index < bounds.upperBound, chars[index].isWhitespace { index += 1 }
        guard index < bounds.upperBound else { return [] }
        starts.append(index)

        var sentenceStart = index
        while index < bounds.upperBound {
            let character = chars[index]
            var boundary: Int?

            if terminators.contains(character) {
                var end = index + 1
                while end < bounds.upperBound, terminators.contains(chars[end]) || closers.contains(chars[end]) { end += 1 }
                if end < bounds.upperBound, chars[end].isWhitespace,
                   isSentenceEnd(chars, stopAt: index, sentenceStart: sentenceStart, closed: closers.contains(chars[end - 1]),
                                 next: nextNonSpace(chars, from: end, limit: bounds.upperBound)) {
                    boundary = nextNonSpace(chars, from: end, limit: bounds.upperBound)
                }
                index = end
            } else if character.isNewline {
                var end = index
                var breaks = 0
                while end < bounds.upperBound, chars[end].isWhitespace {
                    if chars[end].isNewline { breaks += 1 }
                    end += 1
                }
                // "\r\n" is a single Character, so it counts once.
                if breaks >= 2 || (end < bounds.upperBound && startsNumberedItem(chars, at: end, limit: bounds.upperBound)) {
                    boundary = end
                }
                index = end
            } else {
                // A long run with no sentence end: cut at the last space inside the limit.
                if index - sentenceStart >= maxSentenceLength {
                    var cut = index
                    while cut > sentenceStart, !chars[cut].isWhitespace { cut -= 1 }
                    boundary = cut > sentenceStart ? nextNonSpace(chars, from: cut, limit: bounds.upperBound) : index
                }
                index += 1
            }

            if let boundary, boundary < bounds.upperBound, boundary > sentenceStart {
                starts.append(boundary)
                sentenceStart = boundary
                index = max(index, boundary)
            }
        }

        var ranges: [Range<Int>] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : bounds.upperBound
            // Space before the first sentence belongs to it.
            ranges.append((position == 0 ? bounds.lowerBound : start)..<end)
        }
        return ranges
    }

    /// A Margin at the very end of the text still belongs to the last chapter.
    private static func isInChapter(_ offset: Int, bounds: Range<Int>, textLength: Int) -> Bool {
        offset >= bounds.lowerBound && (offset < bounds.upperBound || (bounds.upperBound == textLength && offset == textLength))
    }

    private static func nextNonSpace(_ chars: [Character], from index: Int, limit: Int) -> Int {
        var next = index
        while next < limit, chars[next].isWhitespace { next += 1 }
        return next
    }

    /// "1. " or "12) " at the start of a line: the next item of a numbered list.
    private static func startsNumberedItem(_ chars: [Character], at index: Int, limit: Int) -> Bool {
        var end = index
        while end < limit, end - index < 3, chars[end].isNumber { end += 1 }
        return end > index && end + 1 < limit && (chars[end] == "." || chars[end] == ")") && chars[end + 1] == " "
    }

    /// Whether the stop at `stopAt` really ends the sentence that began at `sentenceStart`. `closed` says a
    /// closing quote or bracket follows the stop, and `next` is the first Character of the following word.
    private static func isSentenceEnd(_ chars: [Character], stopAt: Int, sentenceStart: Int, closed: Bool, next: Int) -> Bool {
        guard next < chars.count else { return true }
        // `"Why?" he asked.` and `"Fine." she said.`: a lowercase word after a closing quote continues it.
        if closed, chars[next].isLowercase { return false }
        // "!" and "?" otherwise always end a sentence; only a full stop can belong to an abbreviation.
        guard chars[stopAt] == "." else { return true }
        var wordStart = stopAt
        while wordStart > sentenceStart, chars[wordStart - 1].isLetter || chars[wordStart - 1] == "." { wordStart -= 1 }
        let word = String(chars[wordStart..<stopAt])
        // An initial ("J. Smith"). "I" is left out: it ends sentences ("So did I. Then we left.").
        if word.count == 1, word != "I", word.first?.isUppercase == true { return false }
        // A list number ("1. Apples") at the start of a line.
        if word.isEmpty, isListNumber(chars, before: stopAt, sentenceStart: sentenceStart) {
            return false
        }
        let lowered = word.lowercased()
        if leadingAbbreviations.contains(lowered) { return false }
        if numberedAbbreviations.contains(lowered), chars[next].isNumber { return false }
        // "e.g. the", "i.e. when", "et al. said": a lowercase word can't start a new sentence.
        if chars[next].isLowercase, word.contains(".") || trailingAbbreviations.contains(lowered) { return false }
        return true
    }

    /// One or two digits right before `stopAt`, standing alone at the start of the sentence or of a line.
    private static func isListNumber(_ chars: [Character], before stopAt: Int, sentenceStart: Int) -> Bool {
        var start = stopAt
        while start > sentenceStart, chars[start - 1].isNumber { start -= 1 }
        guard stopAt - start >= 1, stopAt - start <= 2 else { return false }
        return start == sentenceStart || chars[start - 1].isNewline
    }

    private static func sentenceIndex(containing offset: Int, in sentences: [Range<Int>]) -> Int {
        guard let first = sentences.first, let last = sentences.last else { return 0 }
        if offset < first.upperBound { return 0 }
        if offset >= last.lowerBound { return sentences.count - 1 }
        var low = 0
        var high = sentences.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sentences[mid].lowerBound <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func trimmedEnd(of range: Range<Int>, in chars: [Character]) -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end, chars[start].isWhitespace { start += 1 }
        while end > start, chars[end - 1].isWhitespace { end -= 1 }
        return start..<end
    }
}
