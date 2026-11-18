import Foundation

/// Holds a friend's early tap on the item screen's Play or "Skip to …" button until its start can run (#3788), and runs
/// it by itself then. The rule for ready or waiting is `FriendArrivalStart`, the memory of the tap is `KeptFriendStart`;
/// this adds the waiting between them and what ends it. It has no view and no model in it: the item screen's small
/// presenter owns one (created with the view, dropped when it goes) and hands it the facts and the way to start.
///
/// A tap that can run now runs at once. A tap that can't is kept, the line shows, and the facts are read again every
/// `pollInterval` until the start is possible, the item changes, the Margins are all heard, the download fails, the
/// screen is left (`cancel()`), or `limit` passes, when the start is made anyway so the ordinary path can say what is
/// missing, as "Skip to the Margins" already does for a reading that never comes.
@MainActor
public final class FriendArrivalKeeper {
    /// What the screen knows when it is asked.
    public struct Facts: Equatable, Sendable {
        public var itemId: String
        public var start: FriendArrivalStart
        /// False once no friend Margin waits: the intro is gone, so a kept tap has nothing to start.
        public var hasMargins: Bool
        /// What the listener is doing, as an opaque value (the playing item and session, whether playback is active).
        /// A kept tap is dropped when it changes: they started something else while it waited.
        public var place: String

        public init(itemId: String, start: FriendArrivalStart, hasMargins: Bool, place: String = "") {
            self.itemId = itemId
            self.start = start
            self.hasMargins = hasMargins
            self.place = place
        }
    }

    public typealias ReadFacts = @MainActor () -> Facts
    public typealias Start = @MainActor (FriendArrivalStart.Choice) -> Void

    private var kept = KeptFriendStart()
    private var waiting: Task<Void, Never>?
    private var readFacts: ReadFacts?
    private var startAction: Start?
    private var began = ContinuousClock.now
    private var keptPlace = ""
    private let announce: @MainActor (String) -> Void
    private let pollInterval: Duration
    private let limit: Duration

    /// Called after the line appears or goes, so a view can redraw.
    public var onChange: (@MainActor () -> Void)?

    /// "Getting the episode ready. It starts by itself." while a tap waits; nil otherwise.
    public var line: String? { kept.waitingLine }

    /// The choice being kept, for tests and for the screen's identifiers.
    public var keptChoice: FriendArrivalStart.Choice? { kept.choice }

    public init(
        announce: @escaping @MainActor (String) -> Void = { _ in },
        pollInterval: Duration = .milliseconds(250),
        limit: Duration = .seconds(FriendArrivalStart.keptLimit)
    ) {
        self.announce = announce
        self.pollInterval = pollInterval
        self.limit = limit
    }

    /// The friend tapped `choice`. Runs it now when it can run, and when it will not become ready by waiting (the
    /// failure card says why); otherwise keeps it.
    public func tap(_ choice: FriendArrivalStart.Choice, facts: @escaping ReadFacts, start: @escaping Start) {
        let current = facts()
        var next = kept
        let before = kept
        let outcome = next.tap(choice, itemId: current.itemId, start: current.start)
        apply(next)
        switch outcome {
        case .start(let chosen):
            stopWaiting()
            start(chosen)
        case .idle:
            stopWaiting()
            start(choice)
        case .kept(let announced):
            // A tap that will never be ready (Play on a failed episode) is not swallowed because Skip is still kept:
            // today's path runs and the failure card says why. The kept Skip carries on.
            if current.start.readiness(of: choice) == .failed {
                start(choice)
                return
            }
            if announced { announce(FriendArrivalStart.waitingLine) }
            // A new kept choice, or another item, starts its own count and its own place.
            if before.choice != kept.choice || before.itemId != kept.itemId || waiting == nil {
                began = ContinuousClock.now
                keptPlace = current.place
            }
            readFacts = facts
            startAction = start
            if waiting == nil { wait() }
        }
    }

    /// The listener left the item screen: nothing is kept and nothing starts later.
    public func cancel() {
        stopWaiting()
        var next = kept
        next.cancel()
        apply(next)
    }

    private func wait() {
        waiting = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(250))
                guard let self, !Task.isCancelled, let facts = readFacts, let start = startAction else { return }
                let current = facts()
                // No Margins left, or the listener started something else meanwhile (Lock Screen, mini player): the tap
                // is dropped, as `WrittenMarginReadings.holdReview` drops its start when the listener moved.
                guard current.hasMargins, current.place == keptPlace else { return finish() }
                var next = kept
                let outcome = next.update(itemId: current.itemId, start: current.start)
                apply(next)
                switch outcome {
                case .start(let chosen):
                    finish()
                    start(chosen)
                    return
                case .idle:
                    return finish()
                case .kept:
                    if ContinuousClock.now - began >= limit, let chosen = kept.choice {
                        finish()
                        start(chosen)
                        return
                    }
                }
            }
        }
    }

    /// Ends the wait from inside it.
    private func finish() {
        stopWaiting()
        var next = kept
        next.cancel()
        apply(next)
    }

    private func stopWaiting() {
        waiting?.cancel()
        waiting = nil
        // The closures hold the screen's view; letting go of them ends the loop's only way back to the presenter.
        readFacts = nil
        startAction = nil
    }

    private func apply(_ next: KeptFriendStart) {
        guard next != kept else { return }
        kept = next
        onChange?()
    }
}
