import Foundation

/// What kind of source an export is about, for the rules that differ between them (#4782).
///
/// A spoken note is the listener's own words, so its export may carry its whole transcript. It counts as native audio
/// to the player from its first Play (`SpokenNotePlaybackWriter` gives it `.nativeMediaFile`), so the media type is
/// checked before the source type. Only the export reads this; the other `isNativeAudio` checks are unchanged.
public enum ExportSourceKind: Equatable, Sendable {
    case text
    case nativeAudio
    case spokenNote

    public static func of(_ item: Item) -> ExportSourceKind {
        if SpokenNoteItem.isSpokenNote(mediaType: item.mediaType) { return .spokenNote }
        switch item.media?.sourceType {
        case .nativeMediaFile, .remoteStream:
            return .nativeAudio
        default:
            return .text
        }
    }
}
