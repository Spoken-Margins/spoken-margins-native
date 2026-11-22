import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one request a list address gets (#4046 PR 6): anonymous, with no cookies, and answered from a session that follows no
/// redirect by itself, so a permanent move (301, 308) is seen and the stored address can follow it.
public enum ListLinkTransport {
    public static let maximumRedirects = 5

    /// A session for list addresses. Each request is the listener's own action, so it is an ordinary short one; no cache, no
    /// cookies, no credentials. Redirects are refused here and followed by `get`, which can judge each hop.
    public static func makeSession(configuration: URLSessionConfiguration? = nil) -> URLSession {
        let configuration = configuration ?? {
            let made = URLSessionConfiguration.ephemeral
            made.timeoutIntervalForRequest = 20
            made.timeoutIntervalForResource = 30
            return made
        }()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public struct Validators: Equatable, Sendable {
        public var etag: String?
        public var lastModified: String?
        public init(etag: String? = nil, lastModified: String? = nil) {
            self.etag = etag
            self.lastModified = lastModified
        }
    }

    public struct Reply: Sendable {
        public var status: Int
        public var data: Data
        public var contentType: String?
        public var validators: Validators
        /// The address that answered.
        public var finalURL: URL
        /// The address to store: where the run of permanent redirects (301, 308) from the first address ends. nil when the first
        /// address answered or the first hop was temporary. A temporary hop later in the chain stops the run but keeps what
        /// it had reached.
        public var permanentURL: URL?
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A transport error: offline, a timeout, a refused connection.
        case network
        /// More than five redirects, a redirect with no usable address, or one that leaves https.
        case badRedirect
        case tooBig
        /// The request was cancelled with its task.
        case cancelled
    }

    /// One GET, following up to five redirects by hand. Validators go only to the first address: they describe that
    /// resource, not where it moved to.
    static func get(
        _ url: URL, accept: String, validators: Validators? = nil, maximumBytes: Int, session: URLSession
    ) async throws -> Reply {
        var current = url
        var permanent: URL?
        var stillPermanent = true
        for hop in 0...maximumRedirects {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.httpShouldHandleCookies = false
            request.setValue(accept, forHTTPHeaderField: "Accept")
            if hop == 0, let validators {
                if let etag = validators.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let modified = validators.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw Failure.cancelled
            } catch let error as URLError where error.code == .cancelled {
                throw Failure.cancelled
            } catch {
                throw Failure.network
            }
            guard let http = response as? HTTPURLResponse else { throw Failure.network }
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard hop < maximumRedirects,
                      let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL,
                      next.scheme?.lowercased() == "https", next.host?.isEmpty == false else { throw Failure.badRedirect }
                if stillPermanent, http.statusCode == 301 || http.statusCode == 308 {
                    permanent = next
                } else {
                    stillPermanent = false
                }
                current = next
                continue
            }
            guard data.count <= maximumBytes else { throw Failure.tooBig }
            return Reply(
                status: http.statusCode,
                data: data,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                validators: Validators(etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified")),
                finalURL: current,
                permanentURL: permanent
            )
        }
        throw Failure.badRedirect
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
