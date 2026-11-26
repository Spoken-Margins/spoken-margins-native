import Foundation

/// When the Library's queue entry shows (#5360).
///
/// Adding the first item to an empty queue from a row's swipe used to grow the top of the Library by the queue
/// entry's height at the same moment the swiped row slid back, so the list jumped under the finger. The entry now
/// waits for the swipe to settle, then comes in on its own. It goes as soon as the queue empties, and a queue already
/// holding items when the Library appears shows its entry with no wait.
///
/// The view calls `appeared(isQueued:)` when the Library appears and `queueChanged(isQueued:)` when the queue goes
/// between empty and not, waits out a `.showAfter`
/// step, then calls `settleFinished(generation:)`; a change in between makes that call a no-op, so a queue that
/// empties again inside the wait never shows the entry.
public struct QueueEntryReveal: Equatable, Sendable {
    /// Long enough for a tapped swipe action's row to spring back, short enough to read as the tap's result.
    public static let settleDelay: Duration = .milliseconds(450)

    public enum Step: Equatable, Sendable {
        case hideNow
        case showAfter(Duration, generation: Int)
    }

    /// True only while a first add's wait runs.
    private var isHeld = false
    private var generation = 0
    /// The queue's state as the view last reported it; nil until the Library first appears.
    private var reported: Bool?

    public init() {}

    /// Whether the entry is on screen for a queue that is or isn't empty. A view draws its body with the new queue
    /// before its change handler runs, so a queue that turned non-empty and hasn't been reported yet stays hidden;
    /// otherwise that first draw would show the entry for a frame and bring the jump back.
    public func showsEntry(isQueued: Bool) -> Bool {
        isQueued && reported == true && !isHeld
    }

    /// The Library appeared: whatever the queue holds now shows with no wait.
    public mutating func appeared(isQueued: Bool) {
        generation += 1
        reported = isQueued
        isHeld = false
    }

    /// The queue went from empty to holding items (`true`), or back (`false`).
    public mutating func queueChanged(isQueued: Bool) -> Step {
        generation += 1
        reported = isQueued
        isHeld = isQueued
        return isQueued ? .showAfter(Self.settleDelay, generation: generation) : .hideNow
    }

    /// Ends a `.showAfter` wait. Returns whether the entry comes in now; false when the queue changed since.
    public mutating func settleFinished(generation finished: Int) -> Bool {
        guard finished == generation, isHeld else { return false }
        isHeld = false
        return true
    }
}
