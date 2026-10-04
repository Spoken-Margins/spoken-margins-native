import Foundation
import XCTest
@testable import SessionKit

final class BridgePublicTransportTests: XCTestCase {
    private let url = BridgeManifestPolicy.production.configURL

    private func fetch(_ body: Data, maximumBytes: Int, declaredLength: Int? = nil) async throws -> (status: Int, body: Data) {
        BridgeResponseProtocol.record(body, declaredLength: declaredLength)
        let configuration = BridgePublicTransport.configuration()
        configuration.protocolClasses = [BridgeResponseProtocol.self]
        return try await BridgePublicTransport.fetch(url, maximumBytes, configuration: configuration)
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

    func testUntrustedEndpointIsRefusedBeforeNetworking() async {
        do {
            _ = try await BridgePublicTransport.fetch(URL(string: "https://elsewhere.example.org/config.json")!, 100)
            XCTFail("untrusted endpoint must be refused")
        } catch {
            XCTAssertEqual(error as? BridgeRefreshError, .untrustedURL)
        }
    }
}

/// URLSession still performs request creation and streams the response; only the
/// network boundary is recorded. No test needs a reachable VPS or local listener.
private final class BridgeResponseProtocol: URLProtocol, @unchecked Sendable {
    private final class Recording: @unchecked Sendable {
        let lock = NSLock()
        var body = Data()
        var declaredLength: Int?
    }
    private static let recording = Recording()

    static func record(_ body: Data, declaredLength: Int?) {
        recording.lock.withLock {
            recording.body = body
            recording.declaredLength = declaredLength
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, length) = Self.recording.lock.withLock { (Self.recording.body, Self.recording.declaredLength) }
        let headers = length.map { ["Content-Length": String($0)] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
