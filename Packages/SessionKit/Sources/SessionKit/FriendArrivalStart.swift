import Foundation

/// When each of the item screen's two pinned buttons can start, and what a tap made too early does (#3788).
///
/// A friend who has just opened Cole's file sees the intro and both buttons from the first frame. The episode may still
/// be downloading, or the first Margin's reading may not be made yet. The Design (#3788, 2026-11-12) keeps such a tap
/// instead of greying the button: one line says so, and the chosen start runs by itself when it can. This type is the
/// rule, with no view and no model in it, so the item screen's small presenter only feeds it facts and acts on what it
/// says.
public struct FriendArrivalStart: Equatable, Sendable {
    /// The two pinned buttons: "Play", and "Skip to Cole's Margins".
    public enum Choice: Equatable, Sendable {
        case play
        case skip
    }

    /// Whether a start can run now.
    public enum Readiness: Equatable, Sendable {
        case ready
        case waiting
        /// It will not become ready by waiting: the episode's download failed. The screen's own failure card says why.
        case failed
    }

    /// What the first Margin in Skip order has to play.
    public enum FirstMarginAudio: Equatable, Sendable {
        /// The friend's recording; `onPhone` is whether its file is here.
        case recording(onPhone: Bool)
        /// A written Margin the phone's voice reads; `isReady` is whether that reading is made.
        case reading(isReady: Bool)
        /// Nothing can play for it. A tap is not held: the review's own path says why, as it does today.
        case unavailable
    }

    /// What Play needs: the item's player can start the episode, streaming or downloaded (today's rule for Play), and
    /// whether the download failed.
    public let play: Readiness
    /// What Skip needs: the first Margin's audio. Never `failed`: a Margin that can't play is reported by the review.
    public let skip: Readiness

    /// - Parameters:
    ///   - episodeCanStart: the item's player can start the episode now.
    ///   - episodeFailed: the episode's download failed, so waiting for it is pointless.
    ///   - firstMargin: the first friend Margin in the order Skip plays them; nil when none waits.
    public init(episodeCanStart: Bool, episodeFailed: Bool = false, firstMargin: FirstMarginAudio?) {
        play = episodeCanStart ? .ready : (episodeFailed ? .failed : .waiting)
        switch firstMargin {
        case .recording(let onPhone): skip = onPhone ? .ready : .waiting
        case .reading(let isReady): skip = isReady ? .ready : .waiting
        case .unavailable, nil: skip = .ready
        }
    }

    public func readiness(of choice: Choice) -> Readiness {
        switch choice {
        case .play: play
        case .skip: skip
        }
    }

    /// The one line above the two buttons while a tap is kept.
    public static let waitingLine = "Getting the episode ready. It starts by itself."
}

/// The tap the friend made before its start was possible, for one item (#3788). Held in a small presenter the item
/// screen owns, created with the view and dropped when it goes, never in `Gate1AppModel`.
public struct KeptFriendStart: Equatable, Sendable {
    /// What the screen should do after telling this the news.
    public enum Outcome: Equatable, Sendable {
        /// Run this start now.
        case start(FriendArrivalStart.Choice)
        /// Nothing to run; the line shows (or stays). `announce` is true once, on the tap that first puts it up.
        case kept(announce: Bool)
        /// Nothing is kept, nothing runs.
        case idle
    }

    public private(set) var itemId: String?
    public private(set) var choice: FriendArrivalStart.Choice?

    public init() {}

    /// "Getting the episode ready. It starts by itself." while a tap waits; nil otherwise.
    public var waitingLine: String? { choice == nil ? nil : FriendArrivalStart.waitingLine }

    /// The friend tapped a button. A start that can run does, and drops anything kept; a start that can't is kept,
    /// replacing a kept tap on the other button. The same button again changes nothing and says nothing more.
    public mutating func tap(
        _ tapped: FriendArrivalStart.Choice, itemId: String, start: FriendArrivalStart
    ) -> Outcome {
        switch start.readiness(of: tapped) {
        case .ready:
            cancel()
            return .start(tapped)
        case .failed:
            // The failure card is already on screen; keeping the tap would wait for nothing.
            cancel()
            return .idle
        case .waiting:
            let announce = choice == nil || self.itemId != itemId
            self.itemId = itemId
            choice = tapped
            return .kept(announce: announce)
        }
    }

    /// The facts changed (the download progressed, a reading finished, another item opened). Returns what to do: run
    /// the kept start when it can, drop it when the item changed or its download failed, else keep waiting.
    public mutating func update(itemId current: String, start: FriendArrivalStart) -> Outcome {
        guard let kept = choice else { return .idle }
        guard itemId == current else {
            cancel()
            return .idle
        }
        switch start.readiness(of: kept) {
        case .ready:
            cancel()
            return .start(kept)
        case .failed:
            cancel()
            return .idle
        case .waiting:
            return .kept(announce: false)
        }
    }

    /// The listener left the item screen, or the screen switched to another item.
    public mutating func cancel() {
        itemId = nil
        choice = nil
    }
}
