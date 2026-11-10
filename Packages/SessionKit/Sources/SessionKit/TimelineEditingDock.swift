import Foundation

/// Whether the playback dock steps aside for the Timeline reflection editor (#4043).
///
/// The dock hides while the editor has focus, so the editor and the keyboard get the screen. It used to come back the
/// moment focus left, while the keyboard was still sliding away; once the keyboard was gone the Timeline's scroll range
/// no longer counted the dock, and the Reflect box and its Import button sat behind it out of reach. Now the dock
/// comes back only after the keyboard has fully left, or straight away when no keyboard was up.
public struct TimelineEditingDock: Equatable, Sendable {
    public private(set) var hidesDock = false
    private var editorHasFocus = false
    private var keyboardOnScreen = false

    public init() {}

    /// The dock is hidden only because the keyboard has not finished leaving.
    public var waitsForKeyboard: Bool { hidesDock && !editorHasFocus }

    public mutating func editorFocusChanged(_ hasFocus: Bool) {
        editorHasFocus = hasFocus
        settle()
    }

    public mutating func keyboardWillShow() {
        keyboardOnScreen = true
    }

    /// Also the fallback when no hide arrives, such as a hardware keyboard that never showed one.
    public mutating func keyboardDidHide() {
        keyboardOnScreen = false
        settle()
    }

    private mutating func settle() {
        if editorHasFocus {
            hidesDock = true
        } else if !keyboardOnScreen {
            hidesDock = false
        }
    }
}
