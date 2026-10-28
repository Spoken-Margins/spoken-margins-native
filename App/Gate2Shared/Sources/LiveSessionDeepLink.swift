import Foundation

/// The links the live session's Lock Screen and Dynamic Island send the app (#2833): `spokenmargins://live-session`
/// opens the live session's screen, and `?action=write` or `?action=speak` also gets the written or the spoken
/// Margin going. Foundation only, so the app and the widget share it.
public enum LiveSessionDeepLink {
    public static let scheme = "spokenmargins"
    public static let host = "live-session"

    public enum Action: String, Sendable, Equatable {
        case open
        case write
        case speak
    }

    public static func url(_ action: Action = .open) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if action != .open { components.queryItems = [URLQueryItem(name: "action", value: action.rawValue)] }
        return components.url!
    }

    /// The action a live-session link asks for. Nil for any other link, a path after the host, an unknown action,
    /// or more than one action.
    public static func action(from url: URL) -> Action? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              url.path.isEmpty || url.path == "/" else { return nil }
        let actions = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name == "action" }
        guard actions.count <= 1 else { return nil }
        guard let value = actions.first?.value else { return actions.isEmpty ? .open : nil }
        return Action(rawValue: value)
    }
}
