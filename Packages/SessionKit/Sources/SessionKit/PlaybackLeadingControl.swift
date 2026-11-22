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

    /// What the toolbar's leading item is, apart from whether it shows.
    public enum SlotKind: Equatable, Sendable { case libraryExit, returnToNow }

    /// The toolbar's leading item. `kind` is what the bar lays out; `isShown` is only whether it is drawn and takes taps.
    public struct Slot: Equatable, Sendable {
        public let kind: SlotKind
        public let isShown: Bool
    }

    /// The bar's content must never depend on scroll state: the item came and went as the Now header scrolled in and out,
    /// which changed the bar's size at large text, which moved the header across its threshold, without end (#4739).
    /// So `kind` is the same for either value of `nowHeaderIsVisible`; only `isShown` follows it.
    public static func slot(pane: Pane, timelineEditorHasFocus: Bool, nowHeaderIsVisible: Bool = true) -> Slot {
        switch control(pane: pane, timelineEditorHasFocus: timelineEditorHasFocus, nowHeaderIsVisible: nowHeaderIsVisible) {
        case .none: Slot(kind: .libraryExit, isShown: false)
        case .libraryExit: Slot(kind: .libraryExit, isShown: true)
        case .returnToNow: Slot(kind: .returnToNow, isShown: true)
        }
    }
}
