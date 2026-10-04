import Foundation

/// What background preparation does before it renders the next chunk of an article (#64).
public enum PreparationChunkDecision: String, Equatable, Sendable {
    case render
    /// The phone is too warm. The manifest is saved as paused and its committed chunks stay;
    /// a later pass resumes at the first missing chunk once the heat clears.
    case pauseForHeat = "pause_for_heat"
    /// Low Power Mode is on, and this job wasn't asked for. It stays queued, untouched.
    case waitForLowPowerMode = "wait_for_low_power_mode"
    /// The listener finished the item or is past the cutoff, so speculative work is dropped.
    /// Committed audio is never deleted for this.
    case dropListenedItem = "drop_listened_item"
}

/// The rules for whether the next prepared-audio chunk may start. The preparation pass asks
/// before every chunk, so the rules are host-tested here instead of living inline in the app.
///
/// - Heat serious or critical pauses every job, explicit ones included.
/// - Low Power Mode allows no automatic work; only an explicit Prepare goes on.
/// - An explicit Prepare overrides the "already listened" skip.
public enum PreparationChunkGate {
    /// Whether the pass may look for automatic work at all (enqueue the Library's items).
    public static func allowsAutomaticWork(thermal: SpeechThermalLevel, isLowPowerModeEnabled: Bool) -> Bool {
        !isTooWarm(thermal) && !isLowPowerModeEnabled
    }

    /// Automatic preparation skips an item the listener finished or nearly finished. Moved here
    /// from the app model unchanged (its cutoff was 99%, the same as "completed" above 98%).
    public static let listenedCutoffPercent = 99

    public static func itemAlreadyListened(_ sessions: [Session]) -> Bool {
        sessions.contains { session in
            session.completedAt != nil
                || session.status == "finished"
                || session.phase == .finished
                || session.completionPercent >= listenedCutoffPercent
        }
    }

    /// Low Power Mode holds every job the listener didn't ask for.
    public static func holdsForLowPowerMode(_ policy: PreparationJobPolicy, isLowPowerModeEnabled: Bool) -> Bool {
        isLowPowerModeEnabled && policy != .explicit
    }

    /// Whether the pass sets a queued job aside before choosing one. Heat comes first: while the
    /// phone is too warm every job stays in line, so the chosen one's manifest is saved as paused
    /// for heat even in Low Power Mode (Codex audit on #765).
    public static func setsAsideForLowPowerMode(
        _ policy: PreparationJobPolicy,
        thermal: SpeechThermalLevel,
        isLowPowerModeEnabled: Bool
    ) -> Bool {
        !isTooWarm(thermal) && holdsForLowPowerMode(policy, isLowPowerModeEnabled: isLowPowerModeEnabled)
    }

    public static func decide(
        policy: PreparationJobPolicy,
        thermal: SpeechThermalLevel,
        isLowPowerModeEnabled: Bool,
        itemAlreadyListened: Bool
    ) -> PreparationChunkDecision {
        // Dropping a speculative job renders nothing, so it goes first whatever the heat.
        if policy != .explicit, itemAlreadyListened { return .dropListenedItem }
        if isTooWarm(thermal) { return .pauseForHeat }
        if holdsForLowPowerMode(policy, isLowPowerModeEnabled: isLowPowerModeEnabled) { return .waitForLowPowerMode }
        return .render
    }

    /// The state to save on the job's manifest for `decision`, or nil to leave it as it is.
    /// Only an active manifest pauses, and only a heat pause resumes, so Stop, failures and
    /// finished audio are never overwritten.
    public static func manifestState(
        after decision: PreparationChunkDecision,
        current: PreparedAudioState
    ) -> PreparedAudioState? {
        switch (decision, current) {
        case (.pauseForHeat, .preparing): .pausedForThermal
        case (.render, .pausedForThermal): .preparing
        default: nil
        }
    }

    static func isTooWarm(_ thermal: SpeechThermalLevel) -> Bool {
        thermal == .serious || thermal == .critical
    }
}
