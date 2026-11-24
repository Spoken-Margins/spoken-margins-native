import Foundation

/// The generated timeline turns that the fixture article's UI tests expect once a session starts (`UITestingLaunchSeed
/// .seedsGeneratedTimeline`): one typed follow-up and its finished response, with two response chapters.
///
/// The seed used to end by re-reading the session, and `SessionEngine.inspectSession` always publishes `.paused`. So
/// every start of the fixture article stopped at once and Now Playing read "Play": J1 text chapters skipped at every
/// integration cut from 2026-10-30 (#5204, first seen as #1815). The seed now leaves playback as the listener's tap
/// left it.
public enum UITestingGeneratedTimeline {
    public static let responseTurnId = "turn-response-001"
    public static let followup = "Can you respond to my interjection?"
    public static let response = """
    <sm_summary>Here is a quick response to your interjection.</sm_summary>
    <sm_response>Here is a quick response to your interjection. First, your test is checking whether generated turns stay easy to navigate. Second, the response chapters should remain tappable in the main timeline.</sm_response>
    <sm_chapters_json>{"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ai-ch-1","title":"Quick Response","anchor":"Here is a quick response"},{"id":"ai-ch-2","title":"Timeline Navigation","anchor":"Second, the response chapters"}]}</sm_chapters_json>
    """

    /// Adds the turns to `sessionId`, the engine's current session, and returns the snapshot to show: still playing when
    /// it was playing or starting before, paused when it was paused.
    @discardableResult
    public static func seed(sessionId: String, engine: SessionEngine) throws -> SessionSnapshot {
        let wasPlaying = engine.snapshot.status.isPlaybackActive
        _ = try engine.submitFollowup(text: followup)
        _ = try engine.aiStreamDelta(turnId: responseTurnId, content: response)
        _ = try engine.aiJobCompleted(turnId: responseTurnId)
        // Re-reading puts the session back in item playback (the follow-up moved it to the conversation phase), but
        // always as paused.
        let reread = try engine.inspectSession(sessionId: sessionId)
        return wasPlaying ? try engine.resumePlayback() : reread
    }
}
