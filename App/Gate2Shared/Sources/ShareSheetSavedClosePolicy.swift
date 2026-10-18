import Foundation

/// Whether the share extension closes itself a moment after "Saved" (#1918). The sighted flow is share,
/// a brief "Saved", close. A listener using VoiceOver or Switch Control needs time to hear the status and
/// reach Done, so the extension then stays until they tap Done.
public enum ShareSheetSavedClosePolicy {
    public static let closeDelay: TimeInterval = 0.35

    public static func closesAutomatically(voiceOverRunning: Bool, switchControlRunning: Bool) -> Bool {
        !voiceOverRunning && !switchControlRunning
    }
}
