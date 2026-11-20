import Foundation

/// What a tap on one of the listener's own Margin rows does (#4233).
///
/// A Margin with a place plays its moment. A moved Margin with no saved place has no moment to play, so its row opens its
/// details instead, the same as a friend's unplaced row (J14 step 6, Design Default 8 on #4233). One answer for the
/// Margins tab, the item screen and the Now screen, so no surface decides it on its own.
public enum MarginRowTap {
    public enum Action: Sendable, Equatable {
        case playMoment
        case openDetails
    }

    public static func action(for margin: Interjection) -> Action {
        margin.hasPlace ? .playMoment : .openDetails
    }
}
