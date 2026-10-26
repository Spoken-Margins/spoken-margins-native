import Foundation

/// How far ahead live narration renders (#1681), and when it works and rests (#2703). Rendering the whole item is the
/// charging-only preparation's job (#74). The live player renders without limit only while the phone is cool, the app
/// is on screen and Low Power Mode is off. Otherwise it renders in bursts: it stops queueing renders once `window` of
/// listening (the high-water mark) is waiting ahead and starts again at the resume mark (the low-water mark), so the
/// CPU, heat and battery are spent close to when the audio is needed and the phone cools between bursts.
///
/// This decides *when* the live chain renders. `OnDeviceCPUBudget` decides *how hard* every renderer may run in the
/// background (#2695). They meet at `OnDeviceCPUBudget.liveReserve`: no rest or deferred voice switch lets the
/// listening ahead fall below it, and below it the live chain skips the budget.
public enum RenderAheadPolicy {
    /// Listening waiting ahead at which a limited render chain rests (the high-water mark). It covers the time iOS may
    /// pause rendering with the app away (#1673): the chain starts again with half of it still waiting.
    public static let window: TimeInterval = 5 * 60
    /// The issue's floor for `window`.
    public static let minimumWindow: TimeInterval = 3 * 60
    /// The high-water mark on external power at `fair` heat or cooler: the battery costs nothing then, and longer
    /// bursts with longer rests suit a phone that can shed the heat (#2703).
    public static let chargingWindow: TimeInterval = 10 * 60
    /// At `critical` heat only what keeps playback going: a few chunks past the playing one, enough that a seam never
    /// waits for a render.
    public static let criticalWindow: TimeInterval = 60
    /// The lowest a rest may let the listening ahead fall before the chain renders again, or before heat moves the
    /// item to a stand-in voice. It is the budget's live reserve, so a burst never starts already short.
    public static let restFloor: TimeInterval = OnDeviceCPUBudget.liveReserve

    /// The listening the chain may render ahead now (the high-water mark); nil when it may render the rest of the item.
    public static func window(appBackgrounded: Bool, conditions: SpeechEngineConditions) -> TimeInterval? {
        if conditions.thermal == .critical { return criticalWindow }
        if appBackgrounded || conditions.thermal == .serious || conditions.isLowPowerModeEnabled {
            let cool = conditions.thermal == .nominal || conditions.thermal == .fair
            if conditions.isOnExternalPower == true, cool, !conditions.isLowPowerModeEnabled { return chargingWindow }
            return max(minimumWindow, window)
        }
        return nil
    }

    /// The share of half the window a resting chain waits down to, by heat: the hotter the phone, the longer it rests.
    static func restShare(_ thermal: SpeechThermalLevel) -> Double {
        switch thermal {
        case .nominal, .critical: 1 // critical already renders only a minute ahead
        case .fair: 0.8
        case .serious: 0.6
        }
    }

    /// Listening ahead at which a resting chain starts again (the low-water mark). Half the window on a cool phone;
    /// lower as heat rises, so rests lengthen, but never below `restFloor`. A voice that renders without healthy
    /// headroom over the listening speed (`VoiceHeadroom`, from the render diagnostics, #2701) keeps the plain half:
    /// it needs the longer lead to refill before the buffer runs dry.
    public static func resumeMark(window: TimeInterval, thermal: SpeechThermalLevel, headroom: Double?) -> TimeInterval {
        let half = window / 2
        guard let headroom, VoiceHeadroom.isHealthy(headroom: headroom) else { return half }
        return max(min(half, restFloor), half * restShare(thermal))
    }

    /// Whether the chain queues its next render, with `listeningAhead` rendered and waiting past the playing chunk.
    /// `resting`: the chain is stopped, waiting for the audio ahead to fall to `resumeAt` (half the window by default).
    public static func rendersNext(
        listeningAhead: TimeInterval, window: TimeInterval?, resting: Bool, resumeAt: TimeInterval? = nil
    ) -> Bool {
        guard let window else { return true }
        return resting ? listeningAhead <= (resumeAt ?? window / 2) : listeningAhead < window
    }

    /// #2703: heat refuses the chosen voice, but enough is rendered ahead that the chain can rest and see whether the
    /// phone cools, instead of moving the item to a stand-in now. Only heat defers; a memory warning switches at once.
    /// Once the listening ahead falls to `restFloor` the switch goes ahead, and from then on #1680's hold keeps the
    /// stand-in to the end of the item, so the voice never bounces.
    public static func defersHeatSwitch(block: SpeechFallbackReason?, listeningAhead: TimeInterval) -> Bool {
        block == .deviceTooWarm && listeningAhead > restFloor
    }

    /// Listening time of `audioSeconds` at the listener's speed.
    public static func listening(audioSeconds: TimeInterval, playbackRate: Double) -> TimeInterval {
        audioSeconds / max(0.25, playbackRate)
    }
}
