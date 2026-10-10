import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ReadLaterDocument: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let url: String
    public let html: String?
    public init(id: String, title: String, url: String, html: String?) {
        self.id = id; self.title = title; self.url = url; self.html = html
    }
}
public struct ReadLaterPage: Sendable {
    public let documents: [ReadLaterDocument]
    public let nextCursor: String?
}
public enum ReadLaterService: String, CaseIterable, Sendable {
    case reader, raindrop
    public var title: String { self == .reader ? "Readwise Reader" : "Raindrop.io" }
}
public struct ReadLaterClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let transport: Transport
    public init(transport: @escaping Transport) { self.transport = transport }
    public func page(service: ReadLaterService, token: String, cursor: String? = nil) async throws -> ReadLaterPage {
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw EditionError.invalid("Enter a valid access token.") }
        let base = service == .reader ? "https://readwise.io/api/v3/list/" : "https://api.raindrop.io/rest/v1/raindrops/0"
        var components = URLComponents(string: base)!
        components.queryItems = service == .reader
            ? [URLQueryItem(name: "location", value: "later"), URLQueryItem(name: "withHtmlContent", value: "true")]
            : [URLQueryItem(name: "perpage", value: "50"), URLQueryItem(name: "sort", value: "-created"), URLQueryItem(name: "page", value: cursor ?? "0")]
        if service == .reader, let cursor { components.queryItems?.append(URLQueryItem(name: "pageCursor", value: cursor)) }
        var request = URLRequest(url: components.url!); request.timeoutInterval = 30
        request.setValue((service == .reader ? "Token " : "Bearer ") + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 401, 403: throw EditionError.invalid(Self.accessRejectedMessage)
            case 429: throw EditionError.invalid("The service rate limit was reached. Wait before refreshing again.")
            // Readwise answers a wrong token with 401, so a 404 from the Reader list means the token
            // works but this account has no Reader (#621). Highlights use a different API. A 404 on a
            // later page is about the cursor, not the account, so it keeps the generic message.
            case 404 where service == .reader && cursor == nil: throw EditionError.invalid(Self.readerUnavailableMessage)
            default: throw EditionError.invalid("The service returned HTTP \(response.statusCode). Try again later.")
            }
        }
        guard data.count <= 12_000_000 else { throw EditionError.invalid("The service response is too large. Import a smaller selection.") }
        if service == .reader {
            struct Document: Decodable {
                let id: String; let title: String?; let source_url: String?; let url: String?
                let html_content: String?; let category: String?; let parent_id: String?
            }
            struct Page: Decodable { let results: [Document]; let nextPageCursor: String? }
            let page = try JSONDecoder().decode(Page.self, from: data)
            return ReadLaterPage(documents: page.results.filter { $0.parent_id == nil && ["article", "email", "rss"].contains($0.category ?? "") }.compactMap { doc in
                guard let url = Self.webURL(doc.source_url ?? doc.url ?? "") else { return nil }
                return ReadLaterDocument(id: "reader:" + doc.id, title: doc.title ?? "Saved article", url: url, html: doc.html_content)
            }, nextCursor: page.nextPageCursor)
        }
        struct Drop: Decodable { let _id: Int; let title: String; let link: String }
        struct Page: Decodable { let result: Bool; let items: [Drop] }
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard page.result else { throw EditionError.invalid("Raindrop could not list bookmarks.") }
        return ReadLaterPage(documents: page.items.compactMap { doc in
            guard let url = Self.webURL(doc.link) else { return nil }
            return ReadLaterDocument(id: "raindrop:\(doc._id)", title: doc.title, url: url, html: nil)
        }, nextCursor: page.items.count == 50 ? String((Int(cursor ?? "0") ?? 0) + 1) : nil)
    }
    /// A 401 or 403: the one answer that says the token itself is not accepted (#944).
    public static let accessRejectedMessage = "Access was rejected. Reconnect with a valid token."
    public static let readerUnavailableMessage = "Reader isn’t available on this Readwise account, so there are no Later articles to list. Sending Margins to Readwise as highlights can still work."

    /// The line under Choose Articles when it lists nothing, so the section never shows a bare
    /// heading (#621). Nil while there are articles to show.
    public static func emptyArticlesLine(
        service: ReadLaterService, connected: Bool, isLoading: Bool, loaded: Bool, failure: String?, documentCount: Int
    ) -> String? {
        guard documentCount == 0 else { return nil }
        if isLoading { return "Fetching articles…" }
        guard connected else { return "Connect \(service.title) above to list its articles here." }
        if let failure { return "No articles loaded. \(failure)" }
        guard loaded else { return "Tap Refresh to list your articles." }
        return service == .reader
            ? "No articles to show. Your Reader Later list has no articles with text."
            : "No articles to show. Your Raindrop bookmarks list is empty."
    }

    private static func webURL(_ value: String) -> String? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return value
    }
}
