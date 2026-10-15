import Foundation

/// How far ahead live narration renders (#1681). Rendering the whole item is the charging-only preparation's job
/// (#74). The live player renders without limit only while the phone is cool, the app is on screen and Low Power Mode
/// is off. Otherwise it stops queueing renders once `window` of listening is waiting ahead and starts again when that
/// falls to half, so the CPU, heat and battery are spent close to when the audio is needed.
public enum RenderAheadPolicy {
    /// Listening waiting ahead at which a limited render chain rests. It covers the time iOS may pause rendering with
    /// the app away (#1673): the chain starts again with half of it still waiting.
    public static let window: TimeInterval = 5 * 60
    /// The issue's floor for `window`.
    public static let minimumWindow: TimeInterval = 3 * 60
    /// At `critical` heat only what keeps playback going: about one chunk past the playing one.
    public static let criticalWindow: TimeInterval = 60

    /// The listening the chain may render ahead now; nil when it may render the rest of the item.
    public static func window(appBackgrounded: Bool, conditions: SpeechEngineConditions) -> TimeInterval? {
        if conditions.thermal == .critical { return criticalWindow }
        if appBackgrounded || conditions.thermal == .serious || conditions.isLowPowerModeEnabled {
            return max(minimumWindow, window)
        }
        return nil
    }

    /// Whether the chain queues its next render, with `listeningAhead` rendered and waiting past the playing chunk.
    /// `resting`: the chain is stopped, waiting for the audio ahead to fall to half the window.
    public static func rendersNext(listeningAhead: TimeInterval, window: TimeInterval?, resting: Bool) -> Bool {
        guard let window else { return true }
        return resting ? listeningAhead <= window / 2 : listeningAhead < window
    }

    /// Listening time of `audioSeconds` at the listener's speed.
    public static func listening(audioSeconds: TimeInterval, playbackRate: Double) -> TimeInterval {
        audioSeconds / max(0.25, playbackRate)
    }
}
