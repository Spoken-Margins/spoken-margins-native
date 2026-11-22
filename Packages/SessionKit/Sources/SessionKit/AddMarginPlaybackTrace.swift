import Foundation

/// What a Shortcut's Add Margin found playing, and what it left, for the developer log (#4926).
///
/// A Shortcut that dictates text and then adds a Margin pauses the item, and the owner's export could not say whether
/// the Dictate step or Add Margin did it: the media interruption handler left no line, and Add Margin none. One
/// `shortcut.add_margin` line now says whether the item was playing, already paused by the system, or paused some
/// other way when Add Margin began, and the same three states when it returned. Read beside the interruption lines,
/// that names the pause: `paused_by_system` before means the system paused it first; `playing` before and `paused`
/// after means Add Margin left it paused. Only states: no text, ids or titles.
public struct AddMarginPlaybackTrace: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case playing
        /// The system paused it and an automatic resume may still be waiting for the interruption to end.
        case pausedBySystem = "paused_by_system"
        /// Paused by the listener, finished, or never started.
        case paused
        case nothingOpen = "nothing_open"
        case failed
    }

    public var before: State
    public var after: State

    public init(before: State, after: State) {
        self.before = before
        self.after = after
    }

    /// The state of the player now. `hasSession` is false when no item is open in the player.
    public static func state(status: PlaybackStatus, pausedBySystem: Bool, hasSession: Bool) -> State {
        guard hasSession else { return .nothingOpen }
        if status.isPlaybackActive { return .playing }
        if status == .failed { return .failed }
        return pausedBySystem ? .pausedBySystem : .paused
    }

    /// `saved` is whether the Margin was kept. `stayedPlaying` is the one a listener notices: it was playing and still is.
    public func fields(saved: Bool) -> [String: String] {
        ["before": before.rawValue, "after": after.rawValue, "saved": String(saved),
         "stayedPlaying": String(before == .playing && after == .playing)]
    }
}
