import Foundation

/// An immutable reader destination captured when the listener taps Text.
/// Content and the initial scroll target travel together through sheet dismissal;
/// later playback ticks do not change the chapter or move the reader's scroll.
public struct PlaybackTextPeek: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let passage: PlaybackLivePassage.Window

    public var chapterTitle: String { passage.chapterTitle ?? "Full Text" }
    public var initialSentenceID: Int? {
        guard let index = passage.currentIndex else { return nil }
        return passage.sentences[index].id
    }

    public init(title: String, text: String, chapters: [Chapter], offset: Int) {
        self.title = title
        // At most one sentence per Character: this keeps the entire chapter
        // available for reading without a second chapter/sentence parser.
        let sentenceLimit = text.count
        passage = PlaybackLivePassage.window(
            text: text, chapters: chapters, offset: offset,
            sentencesBefore: sentenceLimit, sentencesAfter: sentenceLimit
        )
    }
}
