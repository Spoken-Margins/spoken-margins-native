import Foundation

extension PlaybackTextReaderTarget {
    /// The selectable reader's input for this target (#1475, #1547), so the playback screen's reader and the More
    /// sheet's Text button open the same chapter and light the same sentence. The sentence range is converted from
    /// Characters to the UTF-16 units UIKit text views use.
    public var reader: PlaybackLivePassage.Reader {
        var range: NSRange?
        if let sentence,
           let start = text.index(text.startIndex, offsetBy: sentence.lowerBound, limitedBy: text.endIndex),
           let end = text.index(text.startIndex, offsetBy: sentence.upperBound, limitedBy: text.endIndex),
           start < end {
            range = NSRange(start..<end, in: text)
        }
        return PlaybackLivePassage.Reader(chapterTitle: chapterTitle, text: text, currentSentenceRange: range)
    }
}
