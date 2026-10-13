import Foundation

/// Where the playback screen's source-text reader opens (#1547): the chapter that is playing, and the sentence
/// being read inside it.
///
/// Offsets count Characters in the item's stored text, the same unit as `Chapter.startChar` and a playback
/// snapshot's `currentTextStart`.
///
/// The chapter is chosen the way the playback header (`PlaybackChapterLocator.currentChapter`) and the engine's
/// chapter jumps choose it: the last chapter that starts at or before the playhead. A chapter's stored `endChar`
/// is not trusted to pick it, because outlines and maps can carry ranges that overlap or run to the end of the
/// text; the reader shows the text from the chapter's start up to the next chapter's start.
public struct PlaybackTextReaderTarget: Sendable, Equatable, Identifiable {
    /// Index of the chosen chapter in the `chapters` passed to `resolve`; nil when the item has no chapters.
    public let chapterIndex: Int?
    /// The chosen chapter's title; nil when the item has no chapters.
    public let chapterTitle: String?
    /// The Characters of the item's text the reader shows, before trimming.
    public let range: Range<Int>
    /// The shown text, with surrounding whitespace trimmed.
    public let text: String
    /// The sentence being read, as Character offsets into `text`; nil when the playhead is unknown or the
    /// chapter has no text.
    public let sentence: Range<Int>?

    public var id: String { "\(chapterIndex ?? -1):\(range.lowerBound):\(sentence?.lowerBound ?? -1)" }

    public init(chapterIndex: Int?, chapterTitle: String?, range: Range<Int>, text: String, sentence: Range<Int>?) {
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.range = range
        self.text = text
        self.sentence = sentence
    }

    /// The reader target for the playhead at `offset`.
    ///
    /// - `offset` nil or negative means the playhead is unknown: the reader opens at the chapter whose id is
    ///   `fallbackChapterId` (the session's chapter), else the first chapter, at its top, with no sentence lit.
    /// - An offset before the first chapter opens the first chapter; one past the end opens the last.
    /// - With no chapters the reader shows the whole text.
    public static func resolve(
        text: String,
        chapters: [Chapter],
        offset: Int?,
        fallbackChapterId: String? = nil
    ) -> PlaybackTextReaderTarget {
        let characters = Array(text)
        let length = characters.count
        let playhead = offset.flatMap { $0 >= 0 ? min($0, length) : nil }

        let order = chapters.indices.sorted {
            chapters[$0].startChar == chapters[$1].startChar ? $0 < $1 : chapters[$0].startChar < chapters[$1].startChar
        }
        let chosen: Int?
        if order.isEmpty {
            chosen = nil
        } else if let playhead {
            chosen = order.last(where: { clamp(chapters[$0].startChar, length) <= playhead }) ?? order.first
        } else {
            chosen = fallbackChapterId.flatMap { id in order.first(where: { chapters[$0].id == id }) } ?? order.first
        }

        let range: Range<Int>
        if let chosen {
            let start = clamp(chapters[chosen].startChar, length)
            let end = order
                .map { clamp(chapters[$0].startChar, length) }
                .first(where: { $0 > start }) ?? length
            range = start..<end
        } else {
            range = 0..<length
        }

        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, characters[lower].isWhitespace { lower += 1 }
        while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
        let shown = String(characters[lower..<upper])

        var sentence: Range<Int>?
        if let playhead, lower < upper {
            let span = Chapter(id: "reader", title: "", startChar: lower, endChar: upper, percent: 0)
            let window = PlaybackLivePassage.window(
                text: text,
                chapters: [span],
                offset: max(lower, min(playhead, upper - 1)),
                sentencesBefore: 0,
                sentencesAfter: 0
            )
            if let index = window.currentIndex {
                let current = window.sentences[index]
                let start = max(lower, current.start) - lower
                let end = min(upper, current.end) - lower
                if end > start { sentence = start..<end }
            }
        }

        return PlaybackTextReaderTarget(
            chapterIndex: chosen,
            chapterTitle: chosen.map { chapters[$0].title },
            range: range,
            text: shown,
            sentence: sentence
        )
    }

    private static func clamp(_ value: Int, _ length: Int) -> Int {
        max(0, min(value, length))
    }
}
