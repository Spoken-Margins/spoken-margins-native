import Foundation

/// When a touch on the playback scrubber still means "seek here" (#1930). The bar follows a finger that
/// stays near it, and a finger that slides far above or below it cancels: the position goes back to where
/// it was and lifting seeks nowhere. A listener with a tremor or one hand can then undo a stray touch.
public enum ScrubTouchRule {
    public enum Outcome: Equatable, Sendable { case follow, cancel }

    /// Twice the 44 pt touch target: far enough that a deliberate drag along the bar never leaves it.
    public static let cancelDistance = 88.0

    /// `verticalOffset` is how far the finger is from the bar's centre line, in points, either way.
    /// A distance exactly at the limit still follows; a reading that is not a number cancels.
    public static func outcome(verticalOffset: Double) -> Outcome {
        guard verticalOffset.isFinite else { return .cancel }
        return abs(verticalOffset) > cancelDistance ? .cancel : .follow
    }
}
