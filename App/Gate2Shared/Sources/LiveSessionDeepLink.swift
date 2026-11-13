import Foundation

/// The links the live session's Lock Screen and Dynamic Island send the app (#2833): `spokenmargins://live-session`
/// opens the live session's screen, and `?action=write` or `?action=speak` also gets the written or the spoken
/// Margin going, and `?action=photo` the camera for a Margin with a picture (#2708). Foundation only, so the app and the
/// widget share it.
public enum LiveSessionDeepLink {
    public static let scheme = "spokenmargins"
    public static let host = "live-session"

    public enum Action: String, Sendable, Equatable {
        case open
        case write
        case speak
        case photo
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

/// The Margin links on the live session's card (#2833, #2708). A session that offers Photo (a paper book or something
/// else; `LiveSessionPhotoMargin.offers`) gets three capsules with short labels, because three long ones don't fit the
/// card's width; a meeting or an audiobook keeps the two long labels. VoiceOver always hears the full name.
public struct LiveSessionMarginLink: Equatable, Sendable {
    public let action: LiveSessionDeepLink.Action
    public let title: String
    public let accessibilityLabel: String
    public let systemImage: String

    /// The links for a card, left to right. `offersPhoto` is the card's `ContentState.offersPhoto`; absent means no Photo.
    public static func links(offersPhoto: Bool?) -> [LiveSessionMarginLink] {
        let write = LiveSessionMarginLink(action: .write, title: "Write a Margin", accessibilityLabel: "Write a Margin", systemImage: "square.and.pencil")
        let speak = LiveSessionMarginLink(action: .speak, title: "Speak a Margin", accessibilityLabel: "Speak a Margin", systemImage: "mic.fill")
        guard offersPhoto == true else { return [write, speak] }
        return [
            LiveSessionMarginLink(action: .speak, title: "Speak", accessibilityLabel: speak.accessibilityLabel, systemImage: speak.systemImage),
            LiveSessionMarginLink(action: .write, title: "Write", accessibilityLabel: write.accessibilityLabel, systemImage: write.systemImage),
            LiveSessionMarginLink(action: .photo, title: "Photo", accessibilityLabel: "Add a Margin with a photo", systemImage: "camera.fill"),
        ]
    }
}
