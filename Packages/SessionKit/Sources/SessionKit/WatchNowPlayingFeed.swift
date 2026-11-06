import Foundation

/// What the phone tells the Watch about the item it has loaded, and when it says it again (#3494 slice 2). Pure, so the
/// rules are tested on the host; `PlayerRunController.note` calls them on each player snapshot.
public enum WatchNowPlayingFeed {
    /// The position may drift from its prediction by this much before the board is sent again.
    public static let positionTolerance: TimeInterval = 5
    /// The longest title sent. The board travels as an application context, which is small.
    public static let maxTitleLength = 120
    /// Said when the item has no title.
    public static let untitled = "This episode"

    /// The item the player has loaded, as the Watch shows it, or nil when nothing is loaded. Loaded means an item that is
    /// starting, playing, paused, or paused under a Margin being recorded on the phone; an idle or failed player is not.
    public static func nowPlaying(from snapshot: SessionSnapshot, at now: Date) -> WatchNowPlaying? {
        guard let itemId = snapshot.itemId?.trimmingCharacters(in: .whitespacesAndNewlines), !itemId.isEmpty else { return nil }
        switch snapshot.status {
        case .starting, .playing, .paused, .recording: break
        case .idle, .failed: return nil
        }
        let title = (snapshot.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchNowPlaying(
            itemId: itemId,
            title: title.isEmpty ? untitled : String(title.prefix(maxTitleLength)),
            isPlaying: snapshot.status.isPlaybackActive,
            positionMs: max(0, snapshot.currentMediaTimeMs ?? 0),
            positionAt: now,
            rate: snapshot.playbackRate.isFinite && snapshot.playbackRate > 0 ? snapshot.playbackRate : 1
        )
    }

    /// Whether `next` is worth sending, given what was last sent: a different item, title, play state or rate, or a
    /// position off where the Watch will predict it by more than `positionTolerance` (a seek, a skip, a stall). Steady
    /// playback never sends again, because the Watch moves the position on by itself.
    public static func shouldPublish(previous: WatchNowPlaying?, next: WatchNowPlaying?) -> Bool {
        switch (previous, next) {
        case (nil, nil): return false
        case (nil, _?), (_?, nil): return true
        case let (before?, after?):
            if before.itemId != after.itemId || before.title != after.title || before.isPlaying != after.isPlaying || before.rate != after.rate {
                return true
            }
            let predicted = before.position(at: after.positionAt)
            return abs(after.positionMs - predicted) > Int(positionTolerance * 1_000)
        }
    }
}

extension WatchTransport {
    /// The compact command the phone runs for it, the same path as the Lock Screen and the Live Activity.
    public var compactCommand: CompactControlCommand {
        switch self {
        case .play: return .play
        case .pause: return .pause
        case .skipBack: return .skipBack
        case .skipForward: return .skipForward
        }
    }
}

extension WatchEnvelope {
    /// The transport command to run now, if this envelope carries one that is still fresh by the phone's clock.
    public func transportToRun(now: Date) -> WatchTransport? {
        guard case .transport(let transport) = message, transportIsFresh(now: now) else { return nil }
        return transport
    }
}

extension WatchBoard {
    /// This board with the player's item on it.
    public func with(nowPlaying: WatchNowPlaying?) -> WatchBoard {
        var board = self
        board.nowPlaying = nowPlaying
        return board
    }
}
