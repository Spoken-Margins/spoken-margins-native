import Foundation
import SessionKit

/// Names for the audio-session calls on the play-start path, for the main-thread hang probe (#842).
///
/// A play tap runs these on the main thread: taking the playback category, activating the session, and releasing
/// it when the old audio stops. Any of them waits on the audio daemon, and none had a label, so a `main.hang`
/// record from a slow start couldn't say which one held the thread. Each call is wrapped in `scoped(_:_:)`, so the
/// next Diagnostics export names it. Labels are fixed names written in code; they hold no ids or titles.
///
/// `scoped(_:_:)` labels only on the main thread, because the label stack is process-wide.
public enum AudioSessionOperationLabel {
    /// `PlaybackAudioSessionPolicy.ensurePlaybackCategory`'s `setCategory`, which every playback route reaches.
    public static let playbackCategory = "session.playbackCategory"
    /// `PlaybackAudioSessionPolicy.releaseDucking`'s `setCategory`.
    public static let releaseDucking = "session.releaseDucking"
    /// The iOS voice taking the session to play.
    public static let speechActivate = "speech.sessionActivate"
    /// The iOS voice releasing the session when it stops.
    public static let speechRelease = "speech.sessionRelease"
    /// The stream player releasing the session when it stops.
    public static let mediaRelease = "media.sessionRelease"
    /// Supertonic's category and activation, together.
    public static let supertonicActivate = "supertonic.sessionActivate"
    /// The friend-Margin voice releasing the session on pause, which can run before the source starts.
    public static let marginVoiceRelease = "marginVoice.sessionRelease"

    /// Runs `body`, labelled `label` for the hang probe when this is the main thread and unlabelled otherwise
    /// (`MainThreadOperationLabels.scopedOnMainThread`).
    public static func scoped<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        try MainThreadOperationLabels.shared.scopedOnMainThread(label, body)
    }
}
