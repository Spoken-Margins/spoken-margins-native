import Foundation
import SessionKit

enum Gate5BrowserTextHandoffURL {
    static let scheme = "spokenmargins"
    static let host = "browser-text"

    static func handoff(from url: URL) -> BrowserTextHandoff? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == host else {
            return nil
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
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

    static func url(for handoff: BrowserTextHandoff) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
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

    private static func boolValue(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }
}
