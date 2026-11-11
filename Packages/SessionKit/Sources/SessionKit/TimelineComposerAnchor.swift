import Foundation

/// When the Timeline rail scrolls the Reflect box back into view after the playback dock returns (#4043, #4047).
///
/// The dock returns after the editor's keyboard has left, and the box can end up behind it, so the rail scrolls the
/// box above the dock, once when the dock returns and once more when the dock's inset has been laid out. That is only
/// right when the listener ended the editing from the box itself: its Done button or Import button. Focus also
/// leaves when the listener drags the rail to read an earlier entry (the rail dismisses the keyboard as it is
/// dragged) or when a row opens a sheet, and then the rail must stay where the listener put it.
public struct TimelineComposerAnchor: Equatable, Sendable {
    private var endedFromComposer = false
    private var waitsForDockInset = false

    public init() {}

    /// The listener ended the editing with the box's own Done or Import button.
    public mutating func editingEndedFromComposer() {
        endedFromComposer = true
    }

    /// The editor has focus again: nothing from an earlier editing waits any more.
    public mutating func editorGainedFocus() {
        endedFromComposer = false
        waitsForDockInset = false
    }

    /// The listener touched the rail: the scroll position is theirs again.
    public mutating func listenerScrolled() {
        endedFromComposer = false
        waitsForDockInset = false
    }

    /// The dock is back. True when the rail should scroll the box above it now; a second scroll follows `dockInsetGrew`.
    public mutating func dockReturned() -> Bool {
        guard endedFromComposer else { return false }
        endedFromComposer = false
        waitsForDockInset = true
        return true
    }

    /// The rail's bottom inset grew. True once per `dockReturned`, when the dock's height is counted and the box needs
    /// the scroll again.
    public mutating func dockInsetGrew() -> Bool {
        guard waitsForDockInset else { return false }
        waitsForDockInset = false
        return true
    }
}
