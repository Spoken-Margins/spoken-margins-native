import Foundation

/// Which of the listener's own Margins a packet can carry (#4233, PR 4 of the Design).
///
/// A Margin moved from a live session with no playback position (`Interjection.hasPlace == false`) has no place on its
/// item. A packet is a set of Margins a friend hears at the right place in their own copy, so a Margin with no place is
/// left out: never written, never defaulted to the start of the item. One rule for the packet writer, the Share sheet's
/// switches, its counts and the single-Margin share, so none of them decides it alone.
public enum ShareableMargins {
    /// The line on a Margin's row in the Share Margins sheet.
    public static let noPlaceLine = "No place, so it can't be shared"

    /// The line above Review when every Margin the sheet lists has no place.
    public static let allWithoutPlaceLine = "These Margins have no place, so they can't be shared."

    /// "Share this Margin" for one with no place says why nothing opened.
    public static let singleMarginRefusal = "This Margin has no place, so it can't be shared with a friend."

    public static func canShare(_ margin: Interjection) -> Bool { margin.hasPlace }

    /// The Margins a packet may carry, in the order given.
    public static func filter(_ margins: [Interjection]) -> [Interjection] {
        margins.filter(canShare)
    }

    /// The same rule over anything that holds a Margin (a share draft, a snapshot).
    public static func filter<Element>(_ elements: [Element], margin: (Element) -> Interjection) -> [Element] {
        elements.filter { canShare(margin($0)) }
    }
}
