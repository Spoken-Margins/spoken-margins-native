import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SessionKit
import SessionKitFeeds

/// Serves what a test registers, by full URL; anything else is a 404. Keeps every request it saw, with its headers. A 3xx
/// reply is the answer as it stands (the session under test refuses redirects), so the checker's own hop handling is what runs.
final class ListLinkStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError.Code)
    }

    struct Seen: Equatable {
        var url: String
        var headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func reset() {
        lock.withLock {
            replies = [:]
            seen = []
        }
    }

    static func serve(_ url: String, _ reply: Reply) {
        lock.withLock { replies[url] = reply }
    }

    static func serve(_ url: String, status: Int = 200, headers: [String: String] = [:], text: String) {
        serve(url, .response(status: status, headers: headers, body: Data(text.utf8)))
    }

    static func redirect(_ url: String, to location: String, status: Int = 301) {
        serve(url, .response(status: status, headers: ["Location": location], body: Data()))
    }

    static var requested: [String] { lock.withLock { seen.map(\.url) } }
    static func headers(of url: String) -> [String: String]? { lock.withLock { seen.last { $0.url == url }?.headers } }
    static func count(of url: String) -> Int { lock.withLock { seen.filter { $0.url == url }.count } }

    /// A session over this stub, built the way the app builds one (no redirects followed by the session).
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListLinkStubProtocol.self]
        return ListLinkTransport.makeSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.seen.append(Seen(url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:]))
            return Self.replies[url.absoluteString]
        }
        switch reply {
        case let .failure(code)?:
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .response(status, headers, body)?:
            deliver(url: url, status: status, headers: headers, body: body)
        case nil:
            deliver(url: url, status: 404, headers: [:], body: Data())
        }
    }

    private func deliver(url: URL, status: Int, headers: [String: String], body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// An OPML file for the list-link tests.
enum ListLinkFixture {
    struct Row {
        var url: String
        var title = "Show"
        var guid: String?
        var via: String?
    }

    static func opml(title: String? = "A list", rows: [Row] = [], includes: [(url: String, title: String)] = []) -> String {
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\" xmlns:sm=\"https://spokenmargins.com/ns/lists/1\" xmlns:podcast=\"https://podcastindex.org/namespace/1.0\">\n<head>"
        if let title { text += "<title>\(title)</title>" }
        text += "</head>\n<body>\n"
        for row in rows {
            text += "<outline type=\"rss\" text=\"\(row.title)\" xmlUrl=\"\(row.url)\""
            if let guid = row.guid { text += " podcast:guid=\"\(guid)\"" }
            if let via = row.via { text += " sm:via=\"\(via)\"" }
            text += "/>\n"
        }
        for include in includes {
            text += "<outline type=\"include\" text=\"\(include.title)\" url=\"\(include.url)\"/>\n"
        }
        return text + "</body>\n</opml>\n"
    }

    static func feedURL(_ n: Int, host: String = "shows.example") -> String { "https://\(host)/feed\(n).xml" }

    static func rows(_ numbers: ClosedRange<Int>, host: String = "shows.example") -> [Row] {
        numbers.map { Row(url: feedURL($0, host: host), title: "Show \($0)") }
    }

    static func member(_ n: Int, host: String = "shows.example", guid: String? = nil) -> ListMember {
        ListMember(feedKey: FeedURLKey.make(feedURL(n, host: host)) ?? feedURL(n, host: host), podcastGUID: guid)
    }
}
