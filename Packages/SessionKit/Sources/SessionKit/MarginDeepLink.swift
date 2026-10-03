import Foundation

/// A link back to one Margin, `spokenmargins://margin?session=<id>&margin=<id>` (#171).
/// Notes in the notes folder carry it, so tapping it in Obsidian or Files opens that Margin in the app.
public struct MarginDeepLink: Equatable, Sendable {
    public static let scheme = "spokenmargins"
    public static let host = "margin"
    static let maximumIdentifierLength = 400

    public let sessionId: String
    public let marginId: String

    public init(sessionId: String, marginId: String) {
        self.sessionId = sessionId
        self.marginId = marginId
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "session", value: sessionId), URLQueryItem(name: "margin", value: marginId)]
        return components.url!
    }

    /// Accepts only this app's margin links: one session and one margin, and nothing else in the path.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host,
              url.path.isEmpty || url.path == "/",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let sessions = items.filter { $0.name == "session" }.compactMap(\.value)
        let margins = items.filter { $0.name == "margin" }.compactMap(\.value)
        guard sessions.count == 1, margins.count == 1,
              let sessionId = sessions.first, let marginId = margins.first,
              Self.isIdentifier(sessionId), Self.isIdentifier(marginId) else { return nil }
        self.init(sessionId: sessionId, marginId: marginId)
    }

    /// Session ids embed the item id, which can come from a link, so any printable characters are allowed;
    /// line breaks, control characters, blank values and very long values are not.
    static func isIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty && value.count <= maximumIdentifierLength
            && !value.unicodeScalars.contains { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    /// A position in a recording, as a listener reads it: "04:05", "1:02:03".
    public static func clockPosition(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600, minutes = (totalSeconds % 3600) / 60, seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
