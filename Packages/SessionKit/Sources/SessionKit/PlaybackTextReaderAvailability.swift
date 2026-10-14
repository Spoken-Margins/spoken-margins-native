import Foundation

/// Whether the playback screen offers the source-text reader (More > Text, #1547).
///
/// A text item can play two ways: on-device speech over its text (`itemTextTTS`), or from its pre-rendered
/// edition, which the engine reports as `transcriptBackedMedia` with a media clock. Both have the item's text and
/// a playhead mapped onto it (`SessionSnapshot.currentTextStart`), so both offer the reader (#1578). A podcast or
/// other recording is media too, but its transcript is not the item's text, so it does not.
public enum PlaybackTextReaderAvailability {
    /// - Parameters:
    ///   - targetType: the playback snapshot's `targetType`.
    ///   - itemText: the selected item's stored text.
    ///   - itemHasNativeAudio: the item is a recording (a media file or stream) rather than text with narration.
    public static func isAvailable(targetType: String?, itemText: String, itemHasNativeAudio: Bool) -> Bool {
        switch targetType {
        case TargetType.itemTextTTS.rawValue:
            return true
        case TargetType.transcriptBackedMedia.rawValue:
            return !itemHasNativeAudio && itemText.contains { !$0.isWhitespace }
        default:
            return false
        }
    }
}
