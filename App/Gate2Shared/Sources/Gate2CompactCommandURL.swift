import Foundation

public enum Gate2CompactCommandURL {
    #if SPOKEN_MARGINS_LEGACY
    public static let scheme = "spokenmargins-legacy"
    #else
    public static let scheme = "spokenmargins"
    #endif
    public static let host = "compact-control"

    public static func url(command: String, chapterId: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "command", value: command)]
        if let chapterId, !chapterId.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "chapterId", value: chapterId))
        }
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    public static func command(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "command" })?
            .value
    }

    public static func chapterId(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "chapterId" })?
            .value
    }
}
