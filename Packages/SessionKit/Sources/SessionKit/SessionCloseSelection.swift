import Foundation

/// Which item the app selects after a session is closed and saved (#583).
public enum SessionCloseSelection {
    /// Closing from another item's page (the mini player's X) keeps that page. Otherwise, as before, the
    /// item whose session closed is selected, so its page shows the saved session.
    /// - Parameters:
    ///   - closedItemId: the item whose session was closed.
    ///   - pageOnScreen: the item whose page is open, or nil when no item page is showing.
    ///   - navigatesHome: the close also goes to Home (End Session).
    public static func itemId(closing closedItemId: String, pageOnScreen: String?, navigatesHome: Bool) -> String {
        guard !navigatesHome, let pageOnScreen, !pageOnScreen.isEmpty else { return closedItemId }
        return pageOnScreen
    }
}
