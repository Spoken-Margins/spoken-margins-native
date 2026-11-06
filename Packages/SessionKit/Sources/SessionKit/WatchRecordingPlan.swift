import Foundation

/// Where the listener aimed a spoken Margin on the Watch: the item the phone is playing, or the running session (#3494).
public enum WatchRecordingTarget: Equatable, Sendable {
    case episode
    case session

    /// Said in large words on the recording screen, so the target never rests on colour alone.
    public var words: String {
        switch self {
        case .episode: "On this episode"
        case .session: "On the session"
        }
    }
}

/// What the Watch decides when a recording starts and ends: whether to pause the phone's item, which item the Margin
/// is aimed at, and when the phone is played again (#3494; the owner's calls of 2026-11-06 on the issue). Pure, so the
/// rules are tested on the host.
public struct WatchRecordingPlan: Equatable, Sendable {
    /// Under this long, Discard asks nothing and a short clip is simply thrown away. Past it, Discard asks once.
    public static let discardAsksAfter: TimeInterval = 30

    public var target: WatchRecordingTarget
    /// The item the Margin belongs on. Nil for the session, and for "this episode" when the board named no item.
    public var itemTarget: WatchItemTarget?
    /// The Watch paused the phone's item when recording began, so it plays it again when recording ends.
    public var pausedPhone: Bool
    /// The item the Watch paused (the same for either target), so Play is not sent to a different one later.
    public var pausedItemId: String?

    /// Starting a recording at `phoneNow` (the phone's clock) with what the board says is loaded. Record pauses an item
    /// that is playing, whichever the target. An episode target carries where the item is as the Watch works it out, a
    /// fallback for the phone when its own record of playing is missing.
    public static func begin(target: WatchRecordingTarget, nowPlaying: WatchNowPlaying?, phoneNow: Date) -> WatchRecordingPlan {
        var itemTarget: WatchItemTarget?
        if target == .episode, let nowPlaying {
            itemTarget = WatchItemTarget(itemId: nowPlaying.itemId, positionMs: nowPlaying.position(at: phoneNow))
        }
        let pauses = nowPlaying?.isPlaying == true
        return WatchRecordingPlan(target: target, itemTarget: itemTarget, pausedPhone: pauses, pausedItemId: pauses ? nowPlaying?.itemId : nil)
    }

    /// The command to send when recording starts: pause the item that is playing.
    public var pauseOnStart: WatchTransport? { pausedPhone ? .pause : nil }

    /// The command to send when recording ends (Stop or Discard): play again, but only if the Watch paused it, and not
    /// when the board now shows another item or none (the listener moved on). A board still showing the same item, even
    /// playing, gets `play`, which a playing phone ignores.
    public func resumeOnEnd(nowPlaying current: WatchNowPlaying?) -> WatchTransport? {
        guard pausedPhone else { return nil }
        if let current, let pausedItemId, current.itemId != pausedItemId { return nil }
        return .play
    }

    public init(target: WatchRecordingTarget, itemTarget: WatchItemTarget? = nil, pausedPhone: Bool = false, pausedItemId: String? = nil) {
        self.target = target
        self.itemTarget = itemTarget
        self.pausedPhone = pausedPhone
        self.pausedItemId = pausedItemId
    }

    /// Whether Discard asks first, after `elapsed` seconds of recording.
    public func discardAsks(afterRecording elapsed: TimeInterval) -> Bool {
        elapsed >= Self.discardAsksAfter
    }
}
