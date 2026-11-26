import Foundation

// URLSession.AsyncBytes is available on the Apple platforms used by the app.
#if !canImport(FoundationNetworking)
/// Public requests carry no install identity, cookies or credentials. Refuse all
/// redirects, including to another path on our host, and stop reading at the cap.
public enum BridgePublicTransport {
    /// `resourceTimeout` caps the whole download. The 30-second default suits config and manifest files;
    /// a caller allowed megabytes passes a longer one. The 15-second idle timeout stays either way.
    static func configuration(resourceTimeout: TimeInterval = 30) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    public static func fetch(_ url: URL, _ maximumBytes: Int) async throws -> (status: Int, body: Data) {
        try await fetch(url, maximumBytes, configuration: configuration())
    }

    // Injectable only inside SessionKit/tests; the app always uses the anonymous configuration.
    static func fetch(_ url: URL, _ maximumBytes: Int, configuration: URLSessionConfiguration) async throws -> (status: Int, body: Data) {
        guard BridgeManifestPolicy.production.isTrusted(url) else { throw BridgeRefreshError.untrustedURL }
        let session = URLSession(configuration: configuration, delegate: BridgePublicSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard response.expectedContentLength <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

private final class BridgePublicSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif

#if !canImport(FoundationNetworking)
/// Posts one community map transcript (#552) to the owner's server. Like the public fetches it
/// carries no cookies, credentials or install identity, follows no redirect, and refuses any
/// host but the pinned one.
public enum CommunityMapTransport {
    public static func post(_ url: URL, _ body: Data) async throws -> Int {
        try await post(url, body, configuration: BridgePublicTransport.configuration())
    }

    // Injectable only inside SessionKit/tests; the app always uses the anonymous configuration.
    static func post(_ url: URL, _ body: Data, configuration: URLSessionConfiguration) async throws -> Int {
        guard BridgeManifestPolicy.production.isTrusted(url) else { throw BridgeRefreshError.untrustedURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = URLSession(configuration: configuration, delegate: BridgePublicSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
#endif

#if !canImport(FoundationNetworking)
/// Uploads one sealed share link (#487): a multipart body of up to about 20 MB. Like the other public requests it
/// carries no cookies or credentials, follows no redirect, and refuses any host but the pinned one. The key is never
/// in the request: it is the link's `#` part, which only the sender's share sheet sees. With a sender check (#2239)
/// the upload carries one header, the one-use permit the server just handed this install: it is how a later report
/// of the link reaches the right sender. The permit holds no key id and no content.
public enum ShareLinkTransport {
    /// What the server's answer may hold: a small JSON object.
    static let maximumAnswerBytes = 4_096

    public static let post: ShareLinkPost = { url, contentType, body in
        try await post(url, contentType, body, configuration: BridgePublicTransport.configuration(resourceTimeout: 180))
    }

    public static let postWithHeaders: ShareLinkPostWithHeaders = { url, contentType, headers, body in
        try await post(url, contentType, body, headers: headers, configuration: BridgePublicTransport.configuration(resourceTimeout: 180))
    }

    // Injectable only inside SessionKit/tests; the app always uses the anonymous configuration.
    static func post(_ url: URL, _ contentType: String, _ body: Data, headers: [String: String] = [:], configuration: URLSessionConfiguration) async throws -> (status: Int, body: Data) {
        guard BridgeManifestPolicy.production.isTrusted(url) else { throw BridgeRefreshError.untrustedURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers where name != "Content-Type" { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let session = URLSession(configuration: configuration, delegate: BridgePublicSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (answer, response) = try await session.data(for: request)
        guard answer.count <= maximumAnswerBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, answer)
    }
}

/// Posts one small JSON request that carries the install's App Attest identity (#2239): the key id and an assertion
/// in headers, set by `AttestedServerClient`, which only runs after the listener agreed. Unlike the public requests
/// it is deliberately identified, and only to our server: the same host pin, no cookies or credentials, no redirect,
/// and a small answer cap. The body carries no content of the listener's.
public enum AttestedTransport {
    static let maximumAnswerBytes = 4_096

    public static let post: AttestedPost = { url, headers, body in
        try await post(url, headers, body, configuration: BridgePublicTransport.configuration())
    }

    // Injectable only inside SessionKit/tests; the app always uses the anonymous configuration.
    static func post(_ url: URL, _ headers: [String: String], _ body: Data, configuration: URLSessionConfiguration) async throws -> (status: Int, body: Data) {
        guard BridgeManifestPolicy.production.isTrusted(url) else { throw BridgeRefreshError.untrustedURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let session = URLSession(configuration: configuration, delegate: BridgePublicSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (answer, response) = try await session.data(for: request)
        guard answer.count <= maximumAnswerBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, answer)
    }
}
#endif

#if !canImport(FoundationNetworking)
/// Sends one club request (#1799), today only a reply box's (#4675): the sender's phone lists and fetches the answers in
/// its own boxes, closes a box and reports an answer. Like the other public requests it carries no cookies or
/// credentials, follows no redirect, refuses any host but the pinned one and any path outside the club routes, and
/// stops reading at the caller's cap. Its one identity is the request's bearer proof, which names a box, not a phone.
public enum ClubTransport {
    public static let send: ClubClient.Send = { request, maximumBytes in
        try await send(request, maximumBytes, host: ProductServer.host,
                       configuration: BridgePublicTransport.configuration(resourceTimeout: 180))
    }

    // Injectable only inside SessionKit/tests; the app always uses the anonymous configuration.
    static func send(
        _ request: ClubClient.Request, _ maximumBytes: Int, host: String, configuration: URLSessionConfiguration
    ) async throws -> (status: Int, body: Data) {
        // `path` holds the query too (`/api/v1/clubs/<id>/posts?after=3`), so the address is read whole.
        guard request.path.hasPrefix("/api/v1/clubs/"), let url = URL(string: "https://\(host)\(request.path)"),
              BridgeManifestPolicy.production.isTrusted(url) else { throw BridgeRefreshError.untrustedURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        if let bearer = request.bearer { urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let contentType = request.contentType { urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        urlRequest.httpBody = request.body
        let session = URLSession(configuration: configuration, delegate: BridgePublicSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard response.expectedContentLength <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
#endif
