import Foundation

/// What VoiceOver hears as the value of one of the listener's own Margin rows on the Margins tab. The row's star and
/// its live-session photo are pictures, so each is said here instead (#1917, #4180). An empty value says nothing.
public enum MarginRowAccessibility {
    public static let starredValue = "Starred for sharing"

    /// "", "Starred for sharing", "with a photo", or "Starred for sharing, with a photo".
    public static func value(starred: Bool, hasPhoto: Bool) -> String {
        var parts: [String] = []
        if starred { parts.append(starredValue) }
        if hasPhoto { parts.append(LiveSessionPhotoMargin.rowAccessibilityValue) }
        return parts.joined(separator: ", ")
    }
}
