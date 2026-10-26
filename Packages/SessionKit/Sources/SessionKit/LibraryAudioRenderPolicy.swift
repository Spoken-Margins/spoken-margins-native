import Foundation

/// When Library audio may render in the background (#2694). Listening to on-device speech never
/// shares the CPU with Library rendering, and a speech session restored after a kill or relaunch
/// stays quiet until the listener plays it or taps Make available offline. Podcasts are exempt.
public struct LibraryAudioRenderPolicy: Equatable, Sendable {
    /// The listener played something or asked for offline audio since launch.
    public private(set) var listenerHasEngaged = false

    public init() {}

    /// Playing, or tapping Make available offline / Prepare next, ends the post-relaunch hold.
    public mutating func noteListenerEngaged() { listenerHasEngaged = true }

    /// What the player shows right now.
    public struct Playback: Equatable, Sendable {
        public var isPlaybackActive: Bool // playing or starting
        public var isMedia: Bool // a podcast or other recorded audio
        public var hasSession: Bool // a speech item is loaded, even paused

        public init(isPlaybackActive: Bool, isMedia: Bool, hasSession: Bool) {
            self.isPlaybackActive = isPlaybackActive
            self.isMedia = isMedia
            self.hasSession = hasSession
        }
    }

    public func allowsRendering(_ playback: Playback) -> Bool {
        if playback.isMedia { return true } // podcast preparation is exempt
        if playback.isPlaybackActive { return false } // speech playing or starting, however far ahead
        if playback.hasSession, !listenerHasEngaged { return false } // restored and still unplayed
        return true
    }
}
