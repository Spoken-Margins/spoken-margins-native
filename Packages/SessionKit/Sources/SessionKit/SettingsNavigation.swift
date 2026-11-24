import Foundation

/// A Settings page that can be opened by value, from a row or from elsewhere in the app (#4781).
public enum SettingsPage: Hashable, Sendable {
    case voices
    case importInbox
}

/// Pure decisions for the Settings navigation path.
public enum SettingsNavigation {
    /// The path after a request to show `request`.
    ///
    /// No request keeps the current path. A request for the page that is already the only one shown
    /// keeps it too, so a double tap on "See why" shows one page. Any other request replaces the path,
    /// so Back returns to the Settings list.
    public static func path(current: [SettingsPage], request: SettingsPage?) -> [SettingsPage] {
        guard let request, current != [request] else { return current }
        return [request]
    }
}
