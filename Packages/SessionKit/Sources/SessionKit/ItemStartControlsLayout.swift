import Foundation

/// Which of the item screen's start controls stay pinned at the bottom of the screen, and which move into the scrolling
/// content (#5110).
///
/// The main listening button is pinned within thumb reach (#149). Above it the pinned area used to carry, at every text
/// size, the "preparing audio" line, the friend's-arrival line and the second choice ("Skip to Sam's Margins · 3 min",
/// "Listen without them", "Play from the start", #3219, #4125). At the accessibility text sizes each of those grows to
/// several lines, and together with the mini player they covered about half the screen, so the content above showed
/// only the title (Test Desk, AX5, `main` 6e9c2d1e6, 2026-11-23).
///
/// At the accessibility sizes only the main button stays pinned, its text capped (with the Large Content Viewer for a
/// long press), and the rest moves to the top of the scrolling content, right under the title. Below those sizes
/// nothing changes.
public enum ItemStartControlsLayout: Equatable, Sendable {
    /// Every start control is pinned: the layout at the default and large text sizes.
    case allPinned
    /// Only the main button is pinned; the status lines and the second choice sit in the scrolling content.
    case mainButtonPinned

    /// One part of the start controls.
    public enum Part: CaseIterable, Sendable {
        /// "Preparing audio…" while the item's audio is made or fetched.
        case preparingLine
        /// The friend's-arrival line under a kept early tap (#3788).
        case arrivalLine
        /// The big button: Play, Continue, Start listening, Replay, Listen now or "Hear Sam's Margins first".
        case mainButton
        /// The second choice, when a friend's Margins wait.
        case secondChoice
    }

    /// - Parameter accessibilityTextSize: the listener's text size is one of the five accessibility sizes
    ///   (`DynamicTypeSize.isAccessibilitySize`).
    public init(accessibilityTextSize: Bool) {
        self = accessibilityTextSize ? .mainButtonPinned : .allPinned
    }

    /// Whether `part` is drawn in the pinned area at the bottom of the screen.
    public func isPinned(_ part: Part) -> Bool {
        switch self {
        case .allPinned: return true
        case .mainButtonPinned: return part == .mainButton
        }
    }

    /// Whether `part` is drawn in the scrolling content instead. Every part is drawn in exactly one of the two places.
    public func isInline(_ part: Part) -> Bool { !isPinned(part) }

    /// Whether the main button's text is capped in the pinned area. It is capped only where it would otherwise grow past
    /// a size the pinned area can hold; the Large Content Viewer shows it full size on a long press.
    public var capsMainButtonText: Bool { self == .mainButtonPinned }
}
