import Foundation

/// Fields of the playback records that explain a pause or a change of voice the listener didn't ask for (#1109).
/// They hold state and counters, never text from a source or a Margin.
public enum PlaybackDiagnosticFields {
    /// Who narrates and what the listener intends, added to every `playback.state` record. The audio session's
    /// and the player's fields join that record only while playing, so a pause used to arrive with nothing from
    /// the narration client: the log showed the status change and not which part of the client had set it.
    public static func narration(intent: String, systemVoiceActive: Bool) -> [String: String] {
        ["clientIntent": intent, "clientVoice": systemVoiceActive ? "system_voice" : "on_device"]
    }

    /// A fall back to the iOS voice, with the moment it happened. `policyBlock` is what the resource policy read
    /// when the fallback was recorded. "none" means nothing refused rendering at that moment, so a "too warm"
    /// reason was the default for a refused render and not a reading of the phone.
    public static func supertonicFallback(
        code: String,
        reason: SpeechFallbackReason,
        policyBlock: SpeechFallbackReason?,
        conditions: SpeechEngineConditions,
        offset: Int
    ) -> [String: String] {
        [
            "code": code,
            "reason": reason.rawValue,
            "policyBlock": policyBlock?.rawValue ?? "none",
            "conditions": conditions.logDescription,
            "offset": String(offset)
        ]
    }
}
