import Foundation

/// Who may be heard, and what the listener sees while it plays (#1337). The owner heard narration with no
/// mini player: the app's snapshot had lost its session while the narration client kept reading. Whatever path
/// does that again, the app repairs it where the listener comes back (foreground, a Live Activity tap) instead
/// of leaving sound that nothing on screen can control.
public enum NarrationOwnership {
    public enum Repair: String, Equatable, Sendable {
        /// The snapshot and the narration agree: nothing to do.
        case none
        /// The snapshot has no session but the engine's session is playing: show that session again, at its
        /// current place, rather than reconstructing one.
        case adoptEngineSession = "adopt_engine_session"
        /// Neither the snapshot nor the engine has a session, yet the client still reads: stop it. Sound with no
        /// session and no controls is the worst case, and there is nothing to attach a mini player to.
        case stopNarration = "stop_narration"
    }

    /// `engineSessionIsPlaying` is the engine's own live status (after a progress sync), not the app's copy.
    public static func repair(appHasSession: Bool, engineSessionIsPlaying: Bool, narrationIsPlaying: Bool) -> Repair {
        guard !appHasSession else { return .none }
        if engineSessionIsPlaying { return .adoptEngineSession }
        return narrationIsPlaying ? .stopNarration : .none
    }

    /// A `playback.ownershipRepair` record. Hashed tokens and state only: no titles, text or URLs.
    public static func repairRecord(
        trigger: String,
        repair: Repair,
        itemToken: String,
        sessionToken: String,
        narration: [String: String]
    ) -> [String: String] {
        var fields = narration
        fields["trigger"] = trigger
        fields["repair"] = repair.rawValue
        fields["item"] = itemToken
        fields["session"] = sessionToken
        return fields
    }

    /// Whether the mini player shows, with the first condition that hides it.
    public struct MiniPlayerVisibility: Equatable, Sendable {
        public var visible: Bool
        public var reason: String

        public init(visible: Bool, reason: String) {
            self.visible = visible
            self.reason = reason
        }
    }

    /// The one definition of when the mini player shows. The reasons are checked in the order the app has always
    /// applied them, so a hidden mini player names a single cause in the export.
    public static func miniPlayerVisibility(
        hasSession: Bool,
        isDismissing: Bool,
        onPlaybackScreen: Bool,
        phase: SessionPhase
    ) -> MiniPlayerVisibility {
        if !hasSession { return MiniPlayerVisibility(visible: false, reason: "no_session") }
        if isDismissing { return MiniPlayerVisibility(visible: false, reason: "dismissing") }
        if onPlaybackScreen { return MiniPlayerVisibility(visible: false, reason: "on_playback_screen") }
        if phase == .finished { return MiniPlayerVisibility(visible: false, reason: "session_finished") }
        if phase == .abandoned { return MiniPlayerVisibility(visible: false, reason: "session_abandoned") }
        return MiniPlayerVisibility(visible: true, reason: "visible")
    }

    /// A `miniPlayer.visibility` record, taken where the listener returns to the app. With the narration fields
    /// beside it, "hidden: no_session" while the client plays is the #1337 state, named without a guess.
    public static func miniPlayerRecord(
        trigger: String,
        visibility: MiniPlayerVisibility,
        narration: [String: String]
    ) -> [String: String] {
        var fields = narration
        fields["trigger"] = trigger
        fields["visible"] = String(visibility.visible)
        fields["reason"] = visibility.reason
        return fields
    }
}
