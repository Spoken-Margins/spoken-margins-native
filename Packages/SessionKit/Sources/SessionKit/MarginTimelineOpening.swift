import Foundation

/// What opening a Margin in its timeline does to the session in Now Playing (#638).
///
/// A Margin from another session may replace a loaded session only while that session is silent,
/// for example one restored paused at launch. A session that is playing keeps playing; recording is
/// guarded before this decision is made.
public enum MarginTimelineOpening: Equatable, Sendable {
    /// The Margin's session is already loaded.
    case focusLoadedSession
    /// Nothing is loaded, or the loaded session is paused: open the Margin's session, paused.
    case openMarginSession
    /// Another session is playing: leave Now Playing unchanged.
    case keepNowPlaying

    public static func decide(
        loadedSessionID: String?,
        marginSessionID: String,
        loadedSessionIsPlaying: Bool
    ) -> MarginTimelineOpening {
        guard let loadedSessionID else { return .openMarginSession }
        if loadedSessionID == marginSessionID { return .focusLoadedSession }
        return loadedSessionIsPlaying ? .keepNowPlaying : .openMarginSession
    }
}
