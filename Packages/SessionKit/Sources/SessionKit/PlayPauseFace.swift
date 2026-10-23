import Foundation

/// What the Play/Pause button shows and says, chosen in one place so a tap does what the face promises (#2098).
///
/// While a start is pending (`PlaybackStatus.starting`) the engine counts playback as active, so a tap pauses it: it
/// cancels the start. The face for that moment says so, instead of a bare spinner that read as "playing soon" and
/// then stopped the audio that was about to start.
public enum PlayPauseFace: Equatable, Sendable {
    case play
    case pause
    /// A start is pending. The button shows its spinner with a stop mark, and a tap cancels the start.
    case cancelStart

    /// `isPlaying` is whether the audio the button controls is playing (a Margin's voice, a skim, or the source).
    /// `tapReachesTheSource` is false while the tap goes to something else (an imported Margin's or own Margin's voice,
    /// a skim, a finished item's replay): a pending start of the source is then not what a tap cancels.
    public init(status: PlaybackStatus, isPlaying: Bool, tapReachesTheSource: Bool = true) {
        self = status == .starting && tapReachesTheSource ? .cancelStart : (isPlaying ? .pause : .play)
    }

    /// Whether a tap stops what is going on, as opposed to starting or resuming it.
    public var tapStops: Bool { self != .play }

    public func accessibilityLabel(isMedia: Bool) -> String {
        switch self {
        case .play: return "Play"
        case .pause: return "Pause"
        case .cancelStart: return "\(PlaybackStartWatch.waitingText(isMedia: isMedia)) Cancel"
        }
    }

    public var accessibilityHint: String? {
        self == .cancelStart ? "Stops the audio that is about to start." : nil
    }
}
