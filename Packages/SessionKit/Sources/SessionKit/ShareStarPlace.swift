import Foundation

/// Where in the app the listener put the sharing star on or off (#4173). The star is the same one everywhere; this only
/// names the screen it came from, so a later slice can count which screens are used without recording any Margin.
public enum ShareStarPlace: String, Codable, CaseIterable, Sendable {
    /// The row on the Now screen (added with the visible slice).
    case now
    /// The player's Margins pane.
    case playerMargins
    /// A Margin's detail screen.
    case detail
    /// Manage Margin.
    case manage
    /// The Margins tab's menu.
    case marginsTab
}

extension Interjection {
    /// Whether a Margin row shows the sharing star (#4173). Share sends only Margins on the source itself, so a Margin on an
    /// assistant reply or a summary has no star: it could never be included, and a starred one would suggest otherwise.
    public var isOfferedShareStar: Bool { targetType == .item }
}
