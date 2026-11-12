import Foundation
import XCTest
@testable import SessionKit

final class BridgePublicTransportTests: XCTestCase {
    private let url = BridgeManifestPolicy.production.configURL
    private static let elsewhere = URL(string: "https://elsewhere.example.org/config.json")!

    override func setUp() {
        super.setUp()
        BridgeResponseProtocol.reset()
    }

    private func stubbedConfiguration() -> URLSessionConfiguration {
        let configuration = BridgePublicTransport.configuration()
        configuration.protocolClasses = [BridgeResponseProtocol.self]
        return configuration
    }

    private func fetch(_ body: Data, maximumBytes: Int, declaredLength: Int? = nil) async throws -> (status: Int, body: Data) {
        BridgeResponseProtocol.reply(.answer(status: 200, body: body, declaredLength: declaredLength))
        return try await BridgePublicTransport.fetch(url, maximumBytes, configuration: stubbedConfiguration())
    }

    func testPublicSessionHasNoPersistentIdentityOrCache() {
        let configuration = BridgePublicTransport.configuration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpAdditionalHeaders)
    }

    func testReadsAResponseThroughURLSessionAtTheExactLimit() async throws {
        let body = Data("manifest".utf8)
        let response = try await fetch(body, maximumBytes: body.count)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, body)
        XCTAssertEqual(BridgeResponseProtocol.requests.map(\.method), ["GET"])
    }

    func testRejectsOversizeWithAndWithoutContentLength() async {
        for length in [nil, 9] as [Int?] {
            do {
                _ = try await fetch(Data("too large".utf8), maximumBytes: 8, declaredLength: length)
                XCTFail("oversize response must be rejected (length: \(String(describing: length)))")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// A server that declares less than it sends is still cut off at the cap while streaming (#1049, LNK-07).
    func testRejectsABodyLongerThanItsDeclaredLength() async {
        do {
            _ = try await fetch(Data("too large".utf8), maximumBytes: 8, declaredLength: 4)
            XCTFail("a body past the cap must be rejected even when Content-Length says it fits")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUntrustedEndpointIsRefusedBeforeNetworking() async {
        BridgeResponseProtocol.reply(.answer(status: 200, body: Data("leak".utf8), declaredLength: nil))
        do {
            _ = try await BridgePublicTransport.fetch(Self.elsewhere, 100, configuration: stubbedConfiguration())
            XCTFail("untrusted endpoint must be refused")
        } catch {
            XCTAssertEqual(error as? BridgeRefreshError, .untrustedURL)
        }
        XCTAssertTrue(BridgeResponseProtocol.requests.isEmpty, "the refusal must come before any request")
    }

    /// The type promises to refuse all redirects (#1049, LNK-07): a 302 comes back as a 302 with no body, and
    /// the place it points to, here another host, is never asked.
    func testRedirectIsNotFollowedAndComesBackAsItsOwnStatus() async throws {
        BridgeResponseProtocol.reply(.redirect(status: 302, to: Self.elsewhere))
        let response = try await BridgePublicTransport.fetch(url, 1_000, configuration: stubbedConfiguration())
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(response.body, Data())
        XCTAssertEqual(BridgeResponseProtocol.requests.map(\.url), [url], "the redirect target must never be requested")
    }

    func testErrorStatusesPassThroughWithTheirBody() async throws {
        for status in [404, 500] {
            BridgeResponseProtocol.reset()
            let body = Data("status \(status)".utf8)
            BridgeResponseProtocol.reply(.answer(status: status, body: body, declaredLength: nil))
            let response = try await BridgePublicTransport.fetch(url, 100, configuration: stubbedConfiguration())
            XCTAssertEqual(response.status, status)
            XCTAssertEqual(response.body, body)
        }
    }
}

/// The community map upload wire (#552) that `CommunityMapUploader` is given in the app (#1049, LNK-02). The
/// uploader's own tests fake this closure, so these send real requests through URLSession and record what
/// reaches the network boundary.
final class CommunityMapTransportTests: XCTestCase {
    private let url = CommunityMapUploader.transcriptsURL

    override func setUp() {
        super.setUp()
        BridgeResponseProtocol.reset()
    }

    private func stubbedConfiguration() -> URLSessionConfiguration {
        let configuration = BridgePublicTransport.configuration()
        configuration.protocolClasses = [BridgeResponseProtocol.self]
        return configuration
    }

    /// A body made by the real upload encoder, as the uploader sends it.
    private func uploadBody() throws -> Data {
        let timeline = TranscriptTimeline(
            segments: [MediaTimelineSegment(id: "s1", startMs: 0, endMs: 30_000, text: "The whole episode, briefly.")],
            chapters: [],
            durationMs: 30_000
        )
        let upload = try XCTUnwrap(CommunityMapTranscriptUpload.make(
            episodeKey: "episode-key", durationMs: 30_000, language: "und", timeline: timeline
        ))
        return try upload.encoded()
    }

    func testPostsTheBodyAsJSONToThePinnedHost() async throws {
        let body = try uploadBody()
        BridgeResponseProtocol.reply(.answer(status: 202, body: Data(), declaredLength: nil))

        let status = try await CommunityMapTransport.post(url, body, configuration: stubbedConfiguration())

        XCTAssertEqual(status, 202)
        let request = try XCTUnwrap(BridgeResponseProtocol.requests.first)
        XCTAssertEqual(BridgeResponseProtocol.requests.count, 1)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.contentType, "application/json")
        XCTAssertEqual(request.body, body, "the server must receive the encoded transcript, byte for byte")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: request.body))
        XCTAssertNil(request.cookie)
        XCTAssertNil(request.authorization)
    }

    func testStatusesPassThroughToTheUploader() async throws {
        let body = try uploadBody()
        for status in [200, 202, 400, 429, 500] {
            BridgeResponseProtocol.reset()
            BridgeResponseProtocol.reply(.answer(status: status, body: Data(), declaredLength: nil))
            let returned = try await CommunityMapTransport.post(url, body, configuration: stubbedConfiguration())
            XCTAssertEqual(returned, status)
        }
    }

    func testRedirectIsNotFollowed() async throws {
        let elsewhere = URL(string: "https://elsewhere.example.org/maps/transcripts")!
        BridgeResponseProtocol.reply(.redirect(status: 302, to: elsewhere))

        let status = try await CommunityMapTransport.post(url, try uploadBody(), configuration: stubbedConfiguration())

        XCTAssertEqual(status, 302)
        XCTAssertEqual(BridgeResponseProtocol.requests.map(\.url), [url], "the transcript must not be sent on to another host")
    }

    func testUntrustedEndpointIsRefusedBeforeNetworking() async throws {
        BridgeResponseProtocol.reply(.answer(status: 202, body: Data(), declaredLength: nil))
        for untrusted in [
            "https://elsewhere.example.org/api/v1/maps/transcripts",
            "http://spokenmargins.proximitytoprogress.com/api/v1/maps/transcripts",
            "https://spokenmargins.proximitytoprogress.com:8443/api/v1/maps/transcripts"
        ] {
            do {
                _ = try await CommunityMapTransport.post(URL(string: untrusted)!, try uploadBody(), configuration: stubbedConfiguration())
                XCTFail("\(untrusted) must be refused")
            } catch {
                XCTAssertEqual(error as? BridgeRefreshError, .untrustedURL, untrusted)
            }
        }
        XCTAssertTrue(BridgeResponseProtocol.requests.isEmpty, "the refusal must come before any request")
    }
}

/// The share link upload wire (#487): real URLSession requests with the network boundary replaced, like the community
/// map upload above.
final class ShareLinkTransportTests: XCTestCase {
    private let url = ProductServer.url(path: ShareLinkClient.linksPath)
    private let contentType = "multipart/form-data; boundary=SM-TEST"

    override func setUp() {
        super.setUp()
        BridgeResponseProtocol.reset()
    }

    private func stubbedConfiguration() -> URLSessionConfiguration {
        let configuration = BridgePublicTransport.configuration(resourceTimeout: 180)
        configuration.protocolClasses = [BridgeResponseProtocol.self]
        return configuration
    }

    func testPostsTheSealedBodyByteForByteToThePinnedHostWithNoIdentity() async throws {
        let body = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        BridgeResponseProtocol.reply(.answer(status: 201, body: Data(#"{"id":"a","path":"/l/a"}"#.utf8), declaredLength: nil))

        let answer = try await ShareLinkTransport.post(url, contentType, body, configuration: stubbedConfiguration())

        XCTAssertEqual(answer.status, 201)
        XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), #"{"id":"a","path":"/l/a"}"#)
        let request = try XCTUnwrap(BridgeResponseProtocol.requests.first)
        XCTAssertEqual(BridgeResponseProtocol.requests.count, 1)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.contentType, contentType)
        XCTAssertEqual(request.body, body)
        XCTAssertNil(request.cookie)
        XCTAssertNil(request.authorization)
    }

    /// #2239: the upload carries the sender check's permit and nothing else of an identity.
    func testTheSenderCheckPermitRidesTheUploadAndNoOtherIdentity() async throws {
        BridgeResponseProtocol.reply(.answer(status: 201, body: Data("{}".utf8), declaredLength: nil))
        _ = try await ShareLinkTransport.post(url, contentType, Data([1]), headers: ["X-SM-Link-Permit": "p-1"], configuration: stubbedConfiguration())
        let request = try XCTUnwrap(BridgeResponseProtocol.requests.first)
        XCTAssertEqual(request.headers["X-SM-Link-Permit"], "p-1")
        XCTAssertEqual(request.contentType, contentType)
        XCTAssertNil(request.headers["X-SM-Key-Id"])
        XCTAssertNil(request.headers["X-SM-Assertion"])
        XCTAssertNil(request.cookie)
        XCTAssertNil(request.authorization)
    }

    func testAnUploadWithNoPermitSendsNoPermitHeader() async throws {
        BridgeResponseProtocol.reply(.answer(status: 201, body: Data("{}".utf8), declaredLength: nil))
        _ = try await ShareLinkTransport.post(url, contentType, Data([1]), configuration: stubbedConfiguration())
        XCTAssertNil(try XCTUnwrap(BridgeResponseProtocol.requests.first).headers["X-SM-Link-Permit"])
    }

    func testStatusesPassThroughToTheClient() async throws {
        for status in [201, 413, 429, 503, 500] {
            BridgeResponseProtocol.reset()
            BridgeResponseProtocol.reply(.answer(status: status, body: Data(), declaredLength: nil))
            let answer = try await ShareLinkTransport.post(url, contentType, Data([1]), configuration: stubbedConfiguration())
            XCTAssertEqual(answer.status, status)
        }
    }

    func testRedirectIsNotFollowedSoTheSealedPacketGoesToNoOtherHost() async throws {
        let elsewhere = URL(string: "https://elsewhere.example.org/api/v1/links")!
        BridgeResponseProtocol.reply(.redirect(status: 307, to: elsewhere))

        let answer = try await ShareLinkTransport.post(url, contentType, Data([1, 2, 3]), configuration: stubbedConfiguration())

        XCTAssertEqual(answer.status, 307)
        XCTAssertEqual(BridgeResponseProtocol.requests.map(\.url), [url])
    }

    func testAnAnswerLargerThanASmallJSONObjectIsRefused() async {
        BridgeResponseProtocol.reply(.answer(status: 201, body: Data(count: ShareLinkTransport.maximumAnswerBytes + 1), declaredLength: nil))
        do {
            _ = try await ShareLinkTransport.post(url, contentType, Data([1]), configuration: stubbedConfiguration())
            XCTFail("an oversized answer must be refused")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUntrustedEndpointIsRefusedBeforeNetworking() async throws {
        BridgeResponseProtocol.reply(.answer(status: 201, body: Data(), declaredLength: nil))
        for untrusted in [
            "https://elsewhere.example.org/api/v1/links",
            "http://spokenmargins.proximitytoprogress.com/api/v1/links",
            "https://spokenmargins.proximitytoprogress.com:8443/api/v1/links",
        ] {
            do {
                _ = try await ShareLinkTransport.post(URL(string: untrusted)!, contentType, Data([1]), configuration: stubbedConfiguration())
                XCTFail("\(untrusted) must be refused")
            } catch {
                XCTAssertEqual(error as? BridgeRefreshError, .untrustedURL, untrusted)
            }
        }
        XCTAssertTrue(BridgeResponseProtocol.requests.isEmpty, "the refusal must come before any request")
    }
}

/// URLSession still builds and sends each request, encodes its body, and streams the response; only the
/// network boundary is replaced. It records every request that reaches it, so a test can tell which URLs
/// were asked for. No test needs a reachable VPS or local listener.
final class BridgeResponseProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case answer(status: Int, body: Data, declaredLength: Int?)
        case redirect(status: Int, to: URL)
    }

    struct Recorded {
        let url: URL?
        let method: String?
        let contentType: String?
        let cookie: String?
        let authorization: String?
        let headers: [String: String]
        let body: Data
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var reply = Reply.answer(status: 200, body: Data(), declaredLength: nil)
        var requests: [Recorded] = []
    }
    private static let state = State()

    static func reset() {
        state.lock.withLock {
            state.reply = .answer(status: 200, body: Data(), declaredLength: nil)
            state.requests = []
        }
    }

    static func reply(_ reply: Reply) {
        state.lock.withLock { state.reply = reply }
    }

    static var requests: [Recorded] { state.lock.withLock { state.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(
            url: request.url,
            method: request.httpMethod,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request)
        )
        let reply = Self.state.lock.withLock {
            Self.state.requests.append(recorded)
            let reply = Self.state.reply
            // Whatever a redirect points to answers 200 with a body, so a followed redirect shows as such.
            if case .redirect = reply { Self.state.reply = .answer(status: 200, body: Data("followed".utf8), declaredLength: nil) }
            return reply
        }
        switch reply {
        case .answer(let status, let body, let length):
            let headers = length.map { ["Content-Length": String($0)] }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let location):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Location": location.absoluteString, "Content-Length": "0"]
            )!
            // The session asks its delegate. A refused redirect leaves this response as the answer; a followed
            // one cancels this load and starts a new one for `location`, which is then recorded too.
            var redirected = URLRequest(url: location)
            redirected.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The attested JSON request (#2239): identified on purpose, and only to the pinned host.
final class AttestedTransportTests: XCTestCase {
    private let url = URL(string: "https://spokenmargins.proximitytoprogress.com/api/v1/links/sender")!

    override func setUp() {
        super.setUp()
        BridgeResponseProtocol.reset()
    }

    override func tearDown() {
        BridgeResponseProtocol.reset()
        super.tearDown()
    }

    private func stubbedConfiguration() -> URLSessionConfiguration {
        let configuration = BridgePublicTransport.configuration()
        configuration.protocolClasses = [BridgeResponseProtocol.self]
        return configuration
    }

    func testSendsTheBodyAndTheAssertionHeadersToThePinnedHostWithNoCookies() async throws {
        BridgeResponseProtocol.reply(.answer(status: 200, body: Data(#"{"sharingAllowed":true}"#.utf8), declaredLength: nil))
        let headers = ["Content-Type": "application/json", "X-SM-Key-Id": "k", "X-SM-Assertion": "a", "X-SM-Time": "1"]
        let answer = try await AttestedTransport.post(url, headers, Data("{}".utf8), configuration: stubbedConfiguration())
        XCTAssertEqual(answer.status, 200)
        let request = try XCTUnwrap(BridgeResponseProtocol.requests.first)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.method, "POST")
        for (name, value) in headers { XCTAssertEqual(request.headers[name], value, name) }
        XCTAssertEqual(request.body, Data("{}".utf8))
        XCTAssertNil(request.cookie)
        XCTAssertNil(request.authorization)
    }

    func testRedirectIsNotFollowed() async throws {
        let elsewhere = URL(string: "https://elsewhere.example.org/x")!
        BridgeResponseProtocol.reply(.redirect(status: 307, to: elsewhere))
        let answer = try await AttestedTransport.post(url, [:], Data(), configuration: stubbedConfiguration())
        XCTAssertEqual(answer.status, 307)
        XCTAssertEqual(BridgeResponseProtocol.requests.map(\.url), [url])
    }

    func testAnOversizedAnswerIsRefused() async {
        BridgeResponseProtocol.reply(.answer(status: 200, body: Data(count: AttestedTransport.maximumAnswerBytes + 1), declaredLength: nil))
        do {
            _ = try await AttestedTransport.post(url, [:], Data(), configuration: stubbedConfiguration())
            XCTFail("an oversized answer must be refused")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The identity headers never leave for another host, a plain-http one or another port.
    func testAnUntrustedEndpointIsRefusedBeforeAnyHeaderIsSent() async {
        for untrusted in [
            "https://elsewhere.example.org/api/v1/links/sender",
            "http://spokenmargins.proximitytoprogress.com/api/v1/links/sender",
            "https://spokenmargins.proximitytoprogress.com:8443/api/v1/links/sender",
        ] {
            do {
                _ = try await AttestedTransport.post(URL(string: untrusted)!, ["X-SM-Key-Id": "k"], Data(), configuration: stubbedConfiguration())
                XCTFail("\(untrusted) must be refused")
            } catch {
                XCTAssertEqual(error as? BridgeRefreshError, .untrustedURL, untrusted)
            }
        }
        XCTAssertTrue(BridgeResponseProtocol.requests.isEmpty)
    }
}
