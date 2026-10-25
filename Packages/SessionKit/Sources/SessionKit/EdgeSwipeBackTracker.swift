import Foundation

/// The state of one edge swipe back to Library, from the first touch to the screen settling (#106).
///
/// The view owns one of these and draws `offset`; every rule about when the screen may move, when a
/// release counts, and which callbacks are ignored lives here so it can be tested on the host. Nothing
/// here touches navigation: the view acts on the `Release` it returns, and only after a commit.
public struct EdgeSwipeBackTracker: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No touch, nothing drawn.
        case idle
        /// A finger is down; the screen follows it once the drag is clearly sideways.
        case dragging
        /// The finger is up and the screen is animating to its resting place; new touches are ignored.
        case settling
    }

    public private(set) var phase: Phase = .idle
    /// How far the screen is drawn from its resting place, in points: 0 to the container's width.
    public private(set) var offset: Double = 0
    /// Whether the drag has been judged sideways. Latched for the rest of the touch, so a swipe that
    /// wanders up or down after it has started moving doesn't make the screen jump back.
    public private(set) var isClaimed = false
    /// Whether the screen has moved at all this touch. Library stays drawn until the swipe is over, so a
    /// cancel's spring back never slides over an empty gap.
    public private(set) var hasMoved = false

    public init() {}

    /// Whether Library should be drawn underneath: from the moment the screen starts to move until the swipe ends.
    public var showsUnderlay: Bool { phase != .idle && hasMoved }

    /// A touch moved. `followsFinger` is false under Reduce Motion, when the screen stays put.
    public mutating func changed(horizontal: Double, vertical: Double, containerWidth: Double, followsFinger: Bool) {
        guard phase != .settling else { return }
        phase = .dragging
        if !isClaimed, EdgeSwipeBackRule.isHorizontalDrag(horizontal: horizontal, vertical: vertical) {
            isClaimed = true
        }
        guard isClaimed, followsFinger, horizontal.isFinite, containerWidth.isFinite, containerWidth > 0 else {
            offset = 0
            return
        }
        offset = min(containerWidth, max(0, horizontal))
        if offset > 0 { hasMoved = true }
    }

    /// The touch ended. Returns what to do, once per touch; an end with no drag in progress, or a second
    /// end for the same touch, returns nil. The view then calls `settle`.
    public mutating func ended(horizontal: Double, vertical: Double, velocity: Double, containerWidth: Double) -> EdgeSwipeBackRule.Outcome? {
        guard phase == .dragging else { return nil }
        phase = .settling
        return EdgeSwipeBackRule.outcome(horizontal: horizontal, vertical: vertical, velocity: velocity, containerWidth: containerWidth)
    }

    /// Moves the drawn screen to where the release sends it: off the far edge on a commit, home on a cancel.
    /// The view calls this inside an animation, so the move starts from the finger's last position.
    public mutating func settle(_ outcome: EdgeSwipeBackRule.Outcome, containerWidth: Double) {
        guard phase == .settling else { return }
        switch outcome {
        case .commit: offset = containerWidth.isFinite ? max(0, containerWidth) : 0
        case .cancel: offset = 0
        }
    }

    /// The screen is at rest, or the swipe was abandoned (recording started, the screen changed, the view went away).
    public mutating func reset() {
        self = EdgeSwipeBackTracker()
    }
}
