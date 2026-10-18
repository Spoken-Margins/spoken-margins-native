import Foundation

/// When the "Moved to Recently Deleted" Undo banner dismisses itself (#1926). A sighted listener gets the
/// short timer. A listener using VoiceOver or Switch Control needs longer than any fixed timer to find and
/// activate Undo, so the banner then stays until they dismiss it, tap Undo, or delete something else.
public enum TrashUndoPolicy {
    /// True when no timer should dismiss the banner.
    public static func staysUntilDismissed(assistiveTechnologyRunning: Bool) -> Bool {
        assistiveTechnologyRunning
    }
}
