import Foundation

/// The one rule for "how long is this recorded audio" that the Library row and the item screen both read (#4186).
///
/// Recorded audio is a podcast episode or other media file (`.nativeMediaFile`, `.remoteStream`). Its length is the
/// media's own `durationMs`, never a reading estimate and never scaled by the listener's speed. Anything else, such
/// as prepared narration of an article (`.generatedTTSPrerendered`), is text: it keeps its "about N min" estimate.
/// A stored 0 or a negative number means "not known yet".
public enum PlayableLength {
    /// The media's length in milliseconds when it is recorded audio of known length, else nil.
    public static func ms(media: ItemMedia?) -> Int? {
        guard let media, media.sourceType == .nativeMediaFile || media.sourceType == .remoteStream,
              let duration = media.durationMs, duration > 0 else { return nil }
        return duration
    }
}
