import Foundation

/// How tall the pinned playback dock may grow at accessibility text sizes (#1933).
///
/// The dock pins the pane switch, chapter row, scrubber, transport and Margin row under every pane. At the
/// largest text sizes it reached about half a 6.1-inch screen, which left the Now view almost nothing. The dock
/// now scrolls inside a bounded height: its own height while that fits under the cap, the cap when it doesn't.
public enum BoundedDockHeight {
    /// The share of the container the dock may take. On an iPhone SE (667 pt) that leaves the Now view about 400 pt
    /// before its own header.
    public static let maxFraction: Double = 0.4

    /// The height to give the dock. `content` is the dock's full height as last measured (0 before the first
    /// measure) and `container` the height it may use a share of.
    public static func height(content: Double, container: Double, maxFraction: Double = BoundedDockHeight.maxFraction) -> Double {
        guard container > 0 else { return max(content, 0) }
        let cap = container * maxFraction
        guard content > 0 else { return cap }
        return min(content, cap)
    }
}
