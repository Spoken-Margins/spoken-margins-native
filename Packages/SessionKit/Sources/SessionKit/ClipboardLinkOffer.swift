import Foundation

/// Whether the Library offers to add a link the listener has copied (#1379).
///
/// The Library may look at the clipboard only through calls that never read it (the change count, and
/// iOS's pattern check for "this looks like a web link"), so the app never appears to read what was
/// copied. This type holds only what those calls return and which copy the listener has already dealt
/// with. A copy is "dealt with" once the listener dismisses the offer, adds the link from it, or opens
/// the Add sheet. The next copy has a new change count and is offered afresh.
public struct ClipboardLinkOffer: Equatable, Sendable {
    /// The change count of the last clipboard check, or nil before the first check.
    public private(set) var changeCount: Int?
    /// Whether the last check found a probable web link.
    public private(set) var holdsProbableLink = false
    /// The change count of the copy the listener last dealt with.
    public private(set) var handledChangeCount: Int?

    public init(handledChangeCount: Int? = nil) {
        self.handledChangeCount = handledChangeCount
    }

    /// True while an unhandled copy that looks like a web link is on the clipboard.
    public var isOffered: Bool {
        guard holdsProbableLink, let changeCount else { return false }
        return changeCount != handledChangeCount
    }

    /// Records a clipboard check, on appearing, returning to the app, or a clipboard change.
    public mutating func observe(changeCount: Int, holdsProbableLink: Bool) {
        self.changeCount = changeCount
        self.holdsProbableLink = holdsProbableLink
    }

    /// The listener dismissed the offer, added the link from it, or opened the Add sheet, which has its own Paste.
    public mutating func markHandled() {
        guard let changeCount else { return }
        handledChangeCount = changeCount
    }
}
