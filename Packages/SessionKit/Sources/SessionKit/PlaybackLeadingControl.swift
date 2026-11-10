import Foundation

/// What the top-left corner of the playback screen does on each tab (#4027).
///
/// The arrow in that corner means one thing on every tab: leave the screen, playback keeps going. Timeline used to
/// show a second arrow that went back to Now, so the same corner meant two things. The one exception is the Timeline
/// editor with the keyboard up: the tab switch is hidden then, so the corner is the only way back to Now.
public enum PlaybackLeadingControl: Equatable, Sendable {
    /// Nothing in the toolbar: on Now the Library button sits in line with the title instead.
    case none
    /// Leave to the Library; playback keeps going.
    case libraryExit
    /// Back to the Now tab, only while the Timeline editor hides the tab switch.
    case returnToNow

    public enum Pane: Equatable, Sendable { case now, timeline, margins }

    public static func control(pane: Pane, timelineEditorHasFocus: Bool) -> PlaybackLeadingControl {
        switch pane {
        case .now: .none
        case .timeline: timelineEditorHasFocus ? .returnToNow : .libraryExit
        case .margins: .libraryExit
        }
    }
}
