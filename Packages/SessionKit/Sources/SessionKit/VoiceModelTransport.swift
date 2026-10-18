import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// How VoiceModelInstaller (#1817) asks the web for bytes. A protocol so the installer's logic is one
// place, and the one real implementation is exercised against a real local HTTP server in the tests.

public struct VoiceModelResponseHead: Equatable, Sendable {
    public var statusCode: Int
    /// The first byte of a `206` body, from `Content-Range: bytes <start>-<end>/<total>`.
    public var contentRangeStart: Int?

    public init(statusCode: Int, contentRangeStart: Int? = nil) {
        self.statusCode = statusCode
        self.contentRangeStart = contentRangeStart
    }
}

public protocol VoiceModelTransport: Sendable {
    /// Requests `url`, asking for `Range: bytes=<offset>-` when `offset` is above zero. Calls `onHead` once
    /// with the response head; it returns whether to read the body, and `false` ends the request without
    /// an error. Hands each piece of body to `onChunk`. Anything either closure throws ends the request
    /// and is rethrown. A connection that drops mid-body throws.
    func fetch(
        _ url: URL,
        from offset: Int,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws
}

public struct URLSessionVoiceModelTransport: VoiceModelTransport {
    private let requestTimeout: TimeInterval

    /// `requestTimeout` is how long a transfer may sit without a byte arriving.
    public init(requestTimeout: TimeInterval = 30) {
        self.requestTimeout = requestTimeout
    }

    public func fetch(
        _ url: URL,
        from offset: Int,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        // Byte counts and ranges must mean the stored bytes, so ask for them uncompressed.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let delegate = TransferDelegate(allowsPlainHTTPRedirects: Self.isLoopback(url), onHead: onHead, onChunk: onChunk)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.begin(continuation, task: session.dataTask(with: request))
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

/// The delegate callbacks arrive one at a time on the session's queue; `cancel()` and `begin` can come
/// from another thread, so every field is guarded by the lock.
private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let allowsPlainHTTPRedirects: Bool
    private let onHead: @Sendable (VoiceModelResponseHead) throws -> Bool
    private let onChunk: @Sendable (Data) throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private var stoppedOnPurpose = false
    private var cancelledByCaller = false

    init(
        allowsPlainHTTPRedirects: Bool,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) {
        self.allowsPlainHTTPRedirects = allowsPlainHTTPRedirects
        self.onHead = onHead
        self.onChunk = onChunk
    }

    func begin(_ continuation: CheckedContinuation<Void, Error>, task: URLSessionDataTask) {
        lock.lock()
        self.continuation = continuation
        self.task = task
        let alreadyCancelled = cancelledByCaller
        lock.unlock()
        if alreadyCancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelledByCaller = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func abort(with error: Error?) {
        lock.lock()
        if let error, failure == nil { failure = error }
        if error == nil { stoppedOnPurpose = true }
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A mirror may redirect to a CDN, but never down to plain HTTP (a local test server excepted).
        let scheme = request.url?.scheme?.lowercased()
        completionHandler(scheme == "https" || allowsPlainHTTPRedirects ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            abort(with: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        let head = VoiceModelResponseHead(
            statusCode: http.statusCode,
            contentRangeStart: Self.rangeStart(http.value(forHTTPHeaderField: "Content-Range"))
        )
        do {
            if try onHead(head) {
                completionHandler(.allow)
            } else {
                abort(with: nil)
                completionHandler(.cancel)
            }
        } catch {
            abort(with: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try onChunk(data)
        } catch {
            abort(with: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        let stoppedOnPurpose = self.stoppedOnPurpose
        let cancelledByCaller = self.cancelledByCaller
        lock.unlock()

        if cancelledByCaller {
            continuation?.resume(throwing: CancellationError())
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else if stoppedOnPurpose {
            continuation?.resume()
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    /// `bytes 100-199/200` gives 100.
    static func rangeStart(_ header: String?) -> Int? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let start = parts[1].split(separator: "-", maxSplits: 1).first
        return start.flatMap { Int($0) }
    }
}
