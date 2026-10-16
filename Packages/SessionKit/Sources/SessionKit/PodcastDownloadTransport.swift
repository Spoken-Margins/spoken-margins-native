import Foundation

public enum PodcastDownloadTransportURLPolicy {
    /// Returns a transport URL that can be used without weakening App Transport Security.
    /// The publisher URL remains on the item as provenance; only the download transport is upgraded.
    public static func secureURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" { return url }
        guard scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.scheme = "https"
        if components.port == 80 { components.port = nil }

        // BBC Media Selector includes the redirect protocol in its path. Changing only the
        // URL scheme still produces an HTTP redirect, so request its HTTPS redirect chain.
        let host = components.host?.lowercased() ?? ""
        if (host == "bbc.co.uk" || host.hasSuffix(".bbc.co.uk")),
           components.percentEncodedPath.contains("/mediaselector/"),
           components.percentEncodedPath.contains("/proto/http/") {
            components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(
                of: "/proto/http/",
                with: "/proto/https/"
            )
        }
        return components.url
    }
}

/// Why a finished download was refused. The text becomes the record's failure reason (#919).
public enum PodcastDownloadFailure: LocalizedError, Equatable {
    case notAudio
    case hostRefused(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .notAudio: "The server sent a web page or text instead of the episode's audio."
        case .hostRefused(let statusCode): "The episode's host refused the download (HTTP \(statusCode))."
        }
    }
}

/// Stored by URLSession with the task, so process reconstruction preserves ownership.
public struct PodcastDownloadAttempt: Codable, Equatable, Sendable {
    public let itemId: String
    public let generation: String
    public let reservationId: String
    public let userInitiated: Bool

    public init(itemId: String, generation: String, reservationId: String, userInitiated: Bool) {
        self.itemId = itemId
        self.generation = generation
        self.reservationId = reservationId
        self.userInitiated = userInitiated
    }

    public var taskDescription: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    public static func decode(_ value: String?) -> Self? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
