import Foundation

/// Fields of the playback records that explain a pause or a change of voice the listener didn't ask for (#1109).
/// They hold state and counters, never text from a source or a Margin.
public enum PlaybackDiagnosticFields {
    /// Who narrates and what the listener intends, added to every `playback.state` record. The audio session's
    /// and the player's fields join that record only while playing, so a pause used to arrive with nothing from
    /// the narration client: the log showed the status change and not which part of the client had set it.
    /// `standInPassage` is true while a short passage read by the iOS voice plays through the on-device
    /// player: `clientVoice` stays `on_device` then, and the listener still hears the iOS voice.
    public static func narration(intent: String, systemVoiceActive: Bool, standInPassage: Bool) -> [String: String] {
        [
            "clientIntent": intent,
            "clientVoice": systemVoiceActive ? "system_voice" : "on_device",
            "clientStandIn": String(standInPassage)
        ]
    }

    /// Which app path closed the engine's session (#1337). The export that started that issue showed the session
    /// gone (`item=none`) with narration still playing, and no record said which path had closed it.
    public enum SessionEndReason: String, Sendable {
        case miniPlayerClose = "mini_player_close"
        case doneButton = "done_button"
        case chapterActionSwitchItem = "chapter_action_switch_item"
        case startNewSession = "start_new_session"
        case itemTrashed = "item_trashed"
    }

    /// Whether the narration client says it is still reading, from the fields `narration(...)` builds.
    public static func narrationIsPlaying(_ narration: [String: String]) -> Bool {
        narration["clientIntent"] == "playing"
    }

    /// A `session.end` record: who closed the session, with the narration client's state before the close.
    /// Items and sessions are hashed tokens, never titles or text.
    public static func sessionEnd(
        reason: SessionEndReason,
        itemToken: String,
        sessionToken: String,
        narration: [String: String]
    ) -> [String: String] {
        var fields = narration
        fields["reason"] = reason.rawValue
        fields["item"] = itemToken
        fields["session"] = sessionToken
        return fields
    }

    /// A `playback.sessionCleared` record: the snapshot lost its item while it was active or paused, whichever path
    /// did it. `narrationOutlivesSession` is true when the client still reads with no session to control it, the
    /// state #1337 found: sound with no mini player. A `session.end` just before it names the path; none means a
    /// path that does not go through `endEngineSession`.
    public static func sessionCleared(
        previousItemToken: String,
        previousSessionToken: String,
        previousStatus: String,
        narration: [String: String]
    ) -> [String: String] {
        var fields = narration
        fields["previousItem"] = previousItemToken
        fields["previousSession"] = previousSessionToken
        fields["previousStatus"] = previousStatus
        fields["narrationOutlivesSession"] = String(narrationIsPlaying(narration))
        return fields
    }

    /// A fall back to the iOS voice, with the moment it happened. `policyBlock` is what the resource policy read
    /// when the app recorded the fallback, which is a moment after the render was refused. "none" means nothing
    /// refused rendering by then, so a "too warm" reason was the default for a refused render and not a reading
    /// of the phone (a refusal for memory pressure whose 60-second backoff ended in that gap reads the same).
    public static func supertonicFallback(
        code: String,
        reason: SpeechFallbackReason,
        policyBlock: SpeechFallbackReason?,
        conditions: SpeechEngineConditions,
        offset: Int,
        voice: String? = nil
    ) -> [String: String] {
        var fields = [
            "code": code,
            "reason": reason.rawValue,
            "policyBlock": policyBlock?.rawValue ?? "none",
            "conditions": conditions.logDescription,
            "offset": String(offset)
        ]
        // The chosen reading voice (#2856): the first Kokoro export could not say whether Kokoro or Phonon had fallen back.
        if let voice { fields["voice"] = voice }
        return fields
    }
}
