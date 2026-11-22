import Foundation

/// Which view shows the sheet that says a friend's link or file could not be opened (#3801, #3782).
///
/// The sheet is one piece of state (`PacketOpenFailureSheetState.presented`), but SwiftUI can present only one sheet at a
/// time from a view and its siblings: a root-level `.sheet` cannot present while the first-launch drawer's sheet is up.
/// A paste over a drawer that has picks leaves the drawer up, so the failure has to show from inside the drawer, or it
/// never shows and the drawer is never told (the audit on PR #4659). Exactly one host owns the state at any moment,
/// so the two can never both bind to it.
public enum PacketOpenFailureHost: Equatable, Sendable {
    /// The app's root view: no drawer is up.
    case root
    /// The first-launch drawer's own sheet: it is up, so a sheet from the root could not appear over it.
    case drawer

    public static func hosting(drawerIsPresented: Bool) -> PacketOpenFailureHost {
        drawerIsPresented ? .drawer : .root
    }
}
