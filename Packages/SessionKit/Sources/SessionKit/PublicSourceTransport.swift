import Foundation

#if !canImport(FoundationNetworking)
/// The live probe behind `PublicSourceVerifier` (#3449): one anonymous request.
///
/// Like the other public requests it carries no cookies, credentials or install identity (an ephemeral session with
/// storage switched off), and unlike them it may name any host, because a source can live anywhere. It follows no redirect
/// itself: the verifier judges each hop. A body is read up to a cap and then dropped, so a large page or a whole episode is
/// never downloaded; an audio start asks for one byte.
public enum PublicSourceTransport {
    static let maximumPageBytes = 2 << 20
    static let maximumAudioBytes = 16

    public static let probe: PublicSourceVerifier.Probe = { url, purpose in
        try await probe(url, purpose, configuration: configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = BridgePublicTransport.configuration(resourceTimeout: 10)
        configuration.timeoutIntervalForRequest = 8
        return configuration
    }

    // Injectable only inside SessionKit/tests; the app always uses the anonymous configuration.
    static func probe(_ url: URL, _ purpose: PublicSourceVerifier.Purpose, configuration: URLSessionConfiguration) async throws -> PublicSourceVerifier.Response {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let cap: Int
        switch purpose {
        case .page:
            cap = maximumPageBytes
            request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        case .audioStart:
            cap = maximumAudioBytes
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var body = Data()
        if (200..<300).contains(http.statusCode) {
            for try await byte in bytes {
                try Task.checkCancellation()
                body.append(byte)
                if body.count >= cap { break }
            }
        }
        let redirect = http.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        return PublicSourceVerifier.Response(
            status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), redirect: redirect, body: body)
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
#endif
