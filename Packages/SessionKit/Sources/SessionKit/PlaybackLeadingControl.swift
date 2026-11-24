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

    /// `nowHeaderIsVisible`: on Now the Library button sits in the header, which the scene's following scrolls out of
    /// sight; while it is, the toolbar shows the same arrow (#4453). Visible, it stays in line with the title.
    public static func control(pane: Pane, timelineEditorHasFocus: Bool, nowHeaderIsVisible: Bool = true) -> PlaybackLeadingControl {
        switch pane {
        case .now: nowHeaderIsVisible ? .none : .libraryExit
        case .timeline: timelineEditorHasFocus ? .returnToNow : .libraryExit
        case .margins: .libraryExit
        }
    }
}

/// Whether the Now header counts as on screen, for the toolbar's Library arrow (#4739).
///
/// The toolbar arrow comes and goes with the header. Adding or removing a toolbar item lays the bar out again, and at
/// the largest text sizes that moved the screen enough to put a header sitting at the edge back on the other side of a
/// single threshold: the arrow flipped on every layout pass, and the app hung at 100% CPU on first launch. Two
/// thresholds break that loop: the header is gone only once almost none of it shows, and back only once almost all of
/// it does. A bar layout that moves the header less than that gap can't undo the last pass. That the move is smaller is
/// read from the code, not measured on a device; the first-run run at AX3 in dark mode on #4739 is the check.
public struct NowHeaderVisibility: Equatable, Sendable {
    /// Below this share of the header on screen, it is gone and the toolbar shows the arrow.
    public static let goneBelow = 0.01
    /// At or above this share, it is back and the arrow returns to the header.
    public static let backAt = 0.9

    public private(set) var isVisible: Bool

    public init(isVisible: Bool = true) {
        self.isVisible = isVisible
    }

    /// What the `goneBelow` threshold reports: whether at least that share of the header is on screen.
    public mutating func reachedGoneThreshold(_ visible: Bool) {
        if !visible { isVisible = false }
    }

    /// What the `backAt` threshold reports: whether at least that share of the header is on screen.
    public mutating func reachedBackThreshold(_ visible: Bool) {
        if visible { isVisible = true }
    }

    /// The same rule from one measured share, for callers that know it.
    public mutating func seen(fraction: Double) {
        reachedGoneThreshold(fraction >= Self.goneBelow)
        reachedBackThreshold(fraction >= Self.backAt)
    }
}
