/// What the share flow does to playback (#5050).
///
/// Opening Share with a Friend while something is sounding (the source, a Margin voice, a Skim bridge) pauses it, and
/// closing the flow leaves it paused: the listener is reading a review, a dialog and the system share sheet, and a
/// source talking under them for a minute is noise they then have to rewind. Pausing and staying paused is what podcast
/// players do. Ducking was the other choice (Default taken on #5050): it keeps the source moving past what the listener
/// was hearing.
///
/// Only the listener resumes. The flow keeps no note that it paused, so nothing can resume on its behalf later.
public enum ShareFlowPlayback: Equatable, Sendable {
    /// Pause what is sounding, through the player's ordinary pause.
    case pause
    /// Leave playback as it is.
    case leaveAlone

    /// The share sheet has just opened.
    public static func onOpen(isPlaying: Bool) -> ShareFlowPlayback {
        isPlaying ? .pause : .leaveAlone
    }

    /// The share flow has closed: sent, cancelled or dismissed. Playback stays as the listener left it, so a source the
    /// share paused stays paused and one the listener restarted under the sheet keeps playing.
    public static func onClose(isPlaying _: Bool) -> ShareFlowPlayback {
        .leaveAlone
    }
}
