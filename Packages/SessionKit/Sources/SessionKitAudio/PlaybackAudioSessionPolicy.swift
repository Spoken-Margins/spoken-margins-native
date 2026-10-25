#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

/// What `AVAudioSession` is set to, as plain values so the decision below is a pure function the host can test.
public struct AudioSessionConfiguration: Equatable, Sendable {
    public var category: String
    public var mode: String
    public var optionsRawValue: UInt

    public init(category: String, mode: String, optionsRawValue: UInt) {
        self.category = category
        self.mode = mode
        self.optionsRawValue = optionsRawValue
    }

    /// `setCategory` is a synchronous round trip to the audio server (tens to hundreds of ms on a Bluetooth
    /// route). When the session already holds the wanted configuration the call changes nothing, so skip it (#2511).
    /// A session whose configuration can't be read (`current` is nil) is always set.
    public static func needsCategoryChange(current: AudioSessionConfiguration?, wanted: AudioSessionConfiguration) -> Bool {
        current != wanted
    }
}

#if canImport(AVFoundation) && os(iOS)
/// Mixing is independent of the explicit request to lower background audio.
public enum PlaybackAudioSessionPolicy {
    public static func options(mixes: Bool, lowersBackground: Bool) -> AVAudioSession.CategoryOptions {
        guard mixes else { return [] }
        return lowersBackground ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
    }

    /// Sets the playback category only when the session isn't already in it. Returns whether it called
    /// `setCategory`. The caller still activates the session: activation is what takes the route, and an
    /// interruption or another component may have deactivated it. A configuration changed by someone else (a
    /// recording over the voice, a ducking Margin) differs from the wanted one, so it is set again.
    @discardableResult
    public static func ensurePlaybackCategory(
        mode: AVAudioSession.Mode = .spokenAudio,
        options: AVAudioSession.CategoryOptions,
        session: AVAudioSession = .sharedInstance()
    ) throws -> Bool {
        let wanted = AudioSessionConfiguration(
            category: AVAudioSession.Category.playback.rawValue,
            mode: mode.rawValue,
            optionsRawValue: options.rawValue
        )
        let current = AudioSessionConfiguration(
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            optionsRawValue: session.categoryOptions.rawValue
        )
        guard AudioSessionConfiguration.needsCategoryChange(current: current, wanted: wanted) else { return false }
        try session.setCategory(.playback, mode: mode, options: options)
        return true
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
