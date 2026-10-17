import Foundation

/// Reads and writes the `<scheme>://browser-text` links that carry a browser text handoff into the app (or a payload
/// id for one the Safari extension and Shortcuts left in the shared store). The scheme is a parameter because the
/// app's build flavors use different ones (`spokenmargins`, `spokenmargins-legacy`); the app picks it.
public struct BrowserTextHandoffURL: Sendable {
    public static let host = "browser-text"

    public let scheme: String

    public init(scheme: String) {
        self.scheme = scheme
    }

    public func isBrowserTextURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == scheme && components.host == Self.host
    }

    public func payloadID(from url: URL) -> String? {
        query(from: url)["payloadId"]
    }

    public func handoff(from url: URL) -> BrowserTextHandoff? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == Self.host else {
            return nil
        }
        let query = query(from: components)
        guard query["payloadId"] == nil else {
            return nil
        }
        guard let text = query["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let sourceURL = query["url"] ?? query["externalReference"] ?? ""
        guard !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let title = query["title"] ?? URLComponents(string: sourceURL)?.host ?? "Browser Text"
        let mode = BrowserTextCaptureMode(rawValue: query["captureMode"] ?? "") ?? .selectedText
        return BrowserTextHandoff(
            itemId: query["itemId"],
            captureMode: mode,
            source: BrowserTextSource(
                url: sourceURL,
                title: title,
                author: query["author"],
                publishedAt: query["publishedAt"]
            ),
            text: text,
            requestedContinuation: BrowserTextContinuation(
                startSession: boolValue(query["startSession"]),
                preferredPlaybackOwner: query["preferredPlaybackOwner"]
            )
        )
    }

    public func handoff(from url: URL, store: Gate5BrowserTextHandoffStore) throws -> BrowserTextHandoff {
        if let payloadID = payloadID(from: url) {
            return try store.handoff(payloadID: payloadID)
        }
        guard let handoff = handoff(from: url) else {
            throw Gate5BrowserTextHandoffStoreError.invalidPayload("unsupported browser text URL")
        }
        return handoff
    }

    public func url(for handoff: BrowserTextHandoff) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = Self.host
        var items = [
            URLQueryItem(name: "captureMode", value: handoff.captureMode.rawValue),
            URLQueryItem(name: "title", value: handoff.source.title),
            URLQueryItem(name: "url", value: handoff.source.url),
            URLQueryItem(name: "text", value: handoff.text),
            URLQueryItem(name: "startSession", value: handoff.requestedContinuation.startSession ? "1" : "0")
        ]
        if let itemId = handoff.itemId {
            items.append(URLQueryItem(name: "itemId", value: itemId))
        }
        if let author = handoff.source.author {
            items.append(URLQueryItem(name: "author", value: author))
        }
        if let publishedAt = handoff.source.publishedAt {
            items.append(URLQueryItem(name: "publishedAt", value: publishedAt))
        }
        if let owner = handoff.requestedContinuation.preferredPlaybackOwner {
            items.append(URLQueryItem(name: "preferredPlaybackOwner", value: owner))
        }
        components.queryItems = items
        return components.url!
    }

    public func url(forPayloadID payloadID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "payloadId", value: payloadID)
        ]
        return components.url!
    }

    private func query(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return [:]
        }
        return query(from: components)
    }

    private func query(from components: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
    }

    private func boolValue(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }
}
