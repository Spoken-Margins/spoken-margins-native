import Foundation

/// Talks to the link server's opened marks (#5275): `POST /l/<id>/opened` with the opened-token as the body
/// when a friend presses Play, and `GET /l/<id>/opened` with the token in a header when the sender's Margins
/// tab asks. Requests go only to ``ProductServer/host``, carry no cookies and no install identity, and are
/// never retried here: a failure is "not sent" or "not known", and the caller tries again later.
public struct ShareLinkOpenedClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    public static let tokenHeader = "X-SM-Opened-Token"

    private let host: String
    private let transport: Transport

    public init(host: String = ProductServer.host, transport: @escaping Transport) {
        self.host = host
        self.transport = transport
    }

    func url(id: String) -> URL {
        ProductServer.url(host: host, path: "/l/\(id)/opened")
    }

    /// Sends the mark. True when the server took the request (it answers 204 whether or not it kept a mark).
    @discardableResult
    public func markOpened(id: String, token: String) async -> Bool {
        guard ShareLinkURL.isID(id), ShareLinkOpenedToken.isValid(token) else { return false }
        var request = URLRequest(url: url(id: id))
        request.httpMethod = "POST"
        request.httpBody = Data(token.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return (try? await transport(request).status) == 204
    }

    /// Whether the link was opened: true or false from the server, false from a server without the route
    /// (404 or 405, before it is deployed), nil when nothing usable came back (offline, 429, 5xx).
    public func isOpened(id: String, token: String) async -> Bool? {
        guard ShareLinkURL.isID(id), ShareLinkOpenedToken.isValid(token) else { return nil }
        var request = URLRequest(url: url(id: id))
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: Self.tokenHeader)
        guard let response = try? await transport(request) else { return nil }
        switch response.status {
        case 200:
            struct Answer: Decodable { let opened: Bool }
            return (try? JSONDecoder().decode(Answer.self, from: response.body))?.opened
        case 404, 405:
            return false
        default:
            return nil
        }
    }

    #if !canImport(FoundationNetworking)
    /// The anonymous public transport: no cookies, no cache, no redirects, the pinned host only.
    public static let live = ShareLinkOpenedClient(transport: { try await BridgePublicTransport.send($0) })
    #endif
}

extension ShareLinkURL {
    /// A link id as the server makes them: 32 lowercase hex characters.
    public static func isID(_ id: String) -> Bool {
        id.utf8.count == idLength && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
