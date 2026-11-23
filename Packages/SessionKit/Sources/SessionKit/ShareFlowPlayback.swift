import Foundation

/// What playback does when the share flow opens and closes (#5050).
///
/// Opening Share while an item plays used to leave the source talking under the "Share as a link?" dialog, the
/// recipient preview and the system share sheet for about a minute. Share is a task that needs the listener's ears
/// and eyes, so it pauses what is playing, as podcast players do. Closing it never resumes: the listener didn't ask
/// for sound, so it stays paused until they press play. Pausing, not ducking, is the Default (#5050).
///
/// This is only the decision. The app asks it once, when the share screen begins, and carries out the answer
/// through the player's own pause, so there is no second playback state or resume flag.
public enum ShareFlowPlayback {
    public enum Action: Equatable, Sendable {
        case pause
        case leaveAlone
    }

    /// `isPlaying` is whether anything is sounding or advancing: the source, a friend's Margin or the listener's own.
    public static func onOpen(isPlaying: Bool) -> Action {
        isPlaying ? .pause : .leaveAlone
    }

    /// Closing the flow, by Cancel, a finished share or a swipe down, starts nothing.
    public static func onClose() -> Action {
        .leaveAlone
    }
}
