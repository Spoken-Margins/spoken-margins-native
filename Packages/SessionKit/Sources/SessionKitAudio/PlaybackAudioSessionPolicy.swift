#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Mixing is independent of the explicit request to lower background audio.
public enum PlaybackAudioSessionPolicy {
    public static func options(mixes: Bool, lowersBackground: Bool) -> AVAudioSession.CategoryOptions {
        guard mixes else { return [] }
        return lowersBackground ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
    }

    /// Called by the active playback route after its audio has stopped. Keep
    /// mixing enabled so releasing ducking never interrupts the other app.
    public static func releaseDucking() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playback, session.categoryOptions.contains(.duckOthers) else { return }
        var options = session.categoryOptions
        options.remove(.duckOthers)
        options.insert(.mixWithOthers)
        try session.setCategory(.playback, mode: .spokenAudio, options: options)
    }
}
#endif
