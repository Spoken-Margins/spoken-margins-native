import Foundation

/// When an edge swipe back to Library commits and when it springs back (#106).
///
/// The screen follows the finger during the drag; on release this rule decides from the drag so far
/// whether to finish the move or return to where it started. It is a pure function of the drag so the
/// view only draws what it says, and nothing about the selected item or playback changes until a drag
/// commits. Distances are points, velocity is points per second, positive towards the trailing edge.
public enum EdgeSwipeBackRule {
    public enum Outcome: Equatable, Sendable {
        case commit
        case cancel
    }

    /// A drag this fraction of the container's width, or further, commits whatever its speed.
    public static let commitFraction = 1.0 / 3.0
    /// A flick at least this fast commits once it has also covered `minimumFlickDistance`.
    public static let commitVelocity = 600.0
    /// A flick shorter than this is a touch that slipped, not a swipe, however fast it was.
    public static let minimumFlickDistance = 24.0
    /// Horizontal travel must exceed vertical travel by this factor, as the swipe has always required,
    /// so a scroll or a scrub that wanders sideways never navigates.
    public static let horizontalDominance = 1.4

    /// Whether the drag so far is a sideways swipe rather than a scroll or a scrub.
    public static func isHorizontalDrag(horizontal: Double, vertical: Double) -> Bool {
        guard horizontal.isFinite, vertical.isFinite else { return false }
        return horizontal > abs(vertical) * horizontalDominance
    }

    /// How far the screen has moved, 0 to 1 of the container's width. This is what the screen follows
    /// and what Library's dimming eases out with; it never goes negative (no peeking the other way) or
    /// past the edge.
    public static func progress(horizontal: Double, containerWidth: Double) -> Double {
        guard horizontal.isFinite, containerWidth.isFinite, containerWidth > 0 else { return 0 }
        return min(1, max(0, horizontal / containerWidth))
    }

    /// What releasing the drag does.
    ///
    /// - Parameters:
    ///   - horizontal: horizontal travel since the drag began, positive towards the trailing edge.
    ///   - vertical: vertical travel since the drag began.
    ///   - velocity: horizontal velocity at release, positive towards the trailing edge.
    ///   - containerWidth: width of the whole screen being moved, not of the 32 pt edge strip the drag starts in.
    public static func outcome(horizontal: Double, vertical: Double, velocity: Double, containerWidth: Double) -> Outcome {
        guard horizontal.isFinite, vertical.isFinite, velocity.isFinite,
              containerWidth.isFinite, containerWidth > 0,
              isHorizontalDrag(horizontal: horizontal, vertical: vertical)
        else { return .cancel }
        // Reversing at speed is a change of mind, even from past the threshold.
        if velocity <= -commitVelocity { return .cancel }
        if progress(horizontal: horizontal, containerWidth: containerWidth) >= commitFraction { return .commit }
        if velocity >= commitVelocity, horizontal >= minimumFlickDistance { return .commit }
        return .cancel
    }
}
