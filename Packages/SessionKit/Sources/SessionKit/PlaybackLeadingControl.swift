import Foundation

/// What the top-left corner of the playback screen does on each tab (#4027).
///
/// The arrow in that corner means one thing on every tab: leave the screen, playback keeps going. Timeline used to
/// show a second arrow that went back to Now, so the same corner meant two things. The one exception is the Timeline
/// editor with the keyboard up: the tab switch is hidden then, so the corner is the only way back to Now.
///
/// On Now the arrow is in the corner too, always (#5329). It used to sit beside the title and move to the bar only once
/// the scene's following scrolled the title away (#4453). The bar kept an invisible copy so its layout could not flip
/// with the scroll (#4739), and iOS 26 drew its glass capsule around that copy: the listener saw an empty pill where the
/// back button belonged. Nothing here depends on scroll state, so the #4739 loop has nothing to feed on.
public enum PlaybackLeadingControl: Equatable, Sendable {
    /// Leave to the Library; playback keeps going.
    case libraryExit
    /// Back to the Now tab, only while the Timeline editor hides the tab switch.
    case returnToNow

    public enum Pane: Equatable, Sendable { case now, timeline, margins }

    /// The identifier the Library arrow carries. There is one arrow on screen, so one identifier (#5311).
    public static let libraryExitIdentifier = "playback.exit.button"

    public static func control(pane: Pane, timelineEditorHasFocus: Bool) -> PlaybackLeadingControl {
        switch pane {
        case .now, .margins: .libraryExit
        case .timeline: timelineEditorHasFocus ? .returnToNow : .libraryExit
        }
    }
}
