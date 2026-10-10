import Foundation

/// What the Lock Screen and Control Center are told about playback (#943). iOS extrapolates the
/// elapsed time from the published rate, so a nonzero rate is a claim that sound is advancing.
/// Only a confirmed `playing` status earns it; `starting` (a slow stream open, the first narration
/// render, a resume still waiting) publishes rate 0 and a loading line, so the clock stays still.
/// `PlaybackStatus.isPlaybackActive` is intent for lifecycle code and is deliberately not used here.
public struct SystemPlaybackPresentation: Equatable, Sendable {
    /// The `MPNowPlayingInfoPropertyPlaybackRate` to publish.
    public let playbackRate: Double
    /// The line that replaces the artist while a start is pending; nil once sound is confirmed or
    /// when nothing is starting.
    public let loadingLine: String?

    public static let loadingAudioLine = "Loading audio…"
    public static let preparingVoiceLine = "Preparing voice…"

    /// - Parameters:
    ///   - selectedRate: the listener's chosen speed.
    ///   - isNarration: the audio is the app's own voice reading text, not a podcast or media file.
    public init(status: PlaybackStatus, selectedRate: Double, isNarration: Bool) {
        playbackRate = status == .playing ? selectedRate : 0
        loadingLine = status == .starting
            ? (isNarration ? Self.preparingVoiceLine : Self.loadingAudioLine)
            : nil
    }
}
