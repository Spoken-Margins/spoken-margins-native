import Foundation

public enum Gate2CompactCommandURL {
    public static let scheme = "spokenmargins"
    public static let host = "compact-control"

    public static func url(command: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "command", value: command)]
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    public static func command(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "command" })?
            .value
    }
}
