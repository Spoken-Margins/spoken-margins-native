import Foundation

/// The playback screen's Margins tab, worded for the listener who has been sent Margins on this item (#3059).
/// Received Margins already sit in place on that tab, but nothing told a friend that was where to look. A count
/// in the label does, in words and a number, so it never rests on colour alone and adds no new control.
public enum PlaybackMarginsTabLabel {
    /// Above this the tab says "99+": the exact count is the tab's job, not the label's.
    public static let displayCap = 99

    /// The number alone, for the icon-only tab at accessibility text sizes. Nil when nothing was received.
    public static func countText(receivedCount: Int) -> String? {
        guard receivedCount > 0 else { return nil }
        return receivedCount > displayCap ? "\(displayCap)+" : String(receivedCount)
    }

    /// What the tab shows. Plain "Margins" when nothing was received.
    public static func title(receivedCount: Int) -> String {
        guard let count = countText(receivedCount: receivedCount) else { return "Margins" }
        return "Margins \(count)"
    }

    /// What VoiceOver reads: the tab name, then how many arrived, spelled out.
    public static func accessibilityLabel(receivedCount: Int) -> String {
        guard receivedCount > 0 else { return "Margins" }
        return "Margins, \(receivedCount) received"
    }
}
