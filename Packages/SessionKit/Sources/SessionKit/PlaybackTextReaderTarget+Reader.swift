import Foundation

extension PlaybackTextReaderTarget {
    /// The selectable reader's input for this target (#1475, #1547), so the playback screen's reader and the More
    /// sheet's Text button open the same chapter and light the same sentence. The sentence range is converted from
    /// Characters to the UTF-16 units UIKit text views use.
    public var reader: PlaybackLivePassage.Reader { reader(footnotes: .none) }

    /// `reader` with footnote markers shown as a listener reads them (#5109); the lit sentence moves with its words.
    public func reader(footnotes: FootnoteDisplayText) -> PlaybackLivePassage.Reader {
        let shown = footnotes.render(text, from: textStart, keeping: sentence)
        let text = shown.text
        var range: NSRange?
        if let sentence = shown.range,
           let start = text.index(text.startIndex, offsetBy: sentence.lowerBound, limitedBy: text.endIndex),
           let end = text.index(text.startIndex, offsetBy: sentence.upperBound, limitedBy: text.endIndex),
           start < end {
            range = NSRange(start..<end, in: text)
        }
        return PlaybackLivePassage.Reader(chapterTitle: chapterTitle, text: text, currentSentenceRange: range)
    }
}
