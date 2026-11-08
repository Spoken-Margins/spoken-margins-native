import Foundation

/// How often the app reads the recorder while a spoken Margin records (#1506).
///
/// The ready cue sounds at the first poll that sees real audio, and the diagnostics' first-audio stamps are
/// read at the same polls. At a fixed 250 ms that adds 0 to 250 ms (125 ms on average) between the recorder
/// taking in its first 100 ms and the listener hearing the cue, on every Margin, speaker or headphones.
/// Reading faster only while the start is unconfirmed removes most of it, and once the cue has sounded
/// (or the start has had its time) the steady 250 ms of a running recording is back.
public enum MarginCapturePollCadence {
    /// Between polls of a running recording.
    public static let steadyMs = 250
    /// Between polls while the start is not yet confirmed. A poll is a meter read; this is 20 a second.
    public static let startupMs = 50
    /// How long after the recording began the fast polls last. Longer than a slow start's grace
    /// (`MarginCaptureTimings.startGraceMs`), so a Bluetooth start that takes a second is still caught quickly.
    public static let startupWindowMs = MarginCaptureTimings.startGraceMs + 1_000

    /// The wait before the next poll. `elapsedMs` is the time since the recording began.
    public static func intervalMs(elapsedMs: Int, cueSounded: Bool) -> Int {
        cueSounded || elapsedMs >= startupWindowMs ? steadyMs : startupMs
    }
}
