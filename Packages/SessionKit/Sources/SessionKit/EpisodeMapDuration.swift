import Foundation

/// Which length the episode-map preparer fingerprints a downloaded file against (#4186).
///
/// The file's own length is the truth: a stored length can be the feed's `itunes:duration`, which the engine calls
/// provisional (ads inserted or removed, a re-upload) until the player observes the real one. Trusting it made the
/// landmark grid run past the end of a shorter file (the run throws) or stop short of a longer one. The stored length
/// is the fallback only when the file's length can't be read.
public enum EpisodeMapDuration {
    /// Milliseconds to build the grid for. 0 when neither is known, as before.
    public static func choose(fileMs: Int?, storedMs: Int?) -> Int {
        if let fileMs, fileMs > 0 { return fileMs }
        if let storedMs, storedMs > 0 { return storedMs }
        return 0
    }
}
