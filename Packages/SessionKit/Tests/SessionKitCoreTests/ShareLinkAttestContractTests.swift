#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import SessionKitTestInputs
import XCTest
@testable import SessionKit

/// The contract between the phone's attested requests and the real Go middleware (#4134, Done when 5). The Swift tests
/// elsewhere talk to hand-written fakes, which can agree with the app and disagree with the server. Here each side checks
/// itself against the same committed files in `Contracts/fixtures/share-link-attest/`:
///
/// - `requests/`: what the app sends, written by this file. Assertions are ECDSA signatures (random) and the Go test's
///   fake device makes fresh keys each run, so a request can't be replayed as is; the file holds what is deterministic
///   (method, path, time, body, the headers other than the assertion, and the hash of the bytes signed). The Go test
///   (`research/B4/server/internal/api/attest_contract_test.go`) recomputes that hash and drives the real `attested`
///   middleware with the same headers.
/// - `responses/`: what the server answers, written by the Go test. This file feeds each one to the app's mapping.
///
/// Files are rewritten only when `SM_REGENERATE_ATTEST_FIXTURES=1` is set, so a normal run never writes to the tree.
final class ShareLinkAttestContractTests: XCTestCase {
    private static let regenerate = ProcessInfo.processInfo.environment["SM_REGENERATE_ATTEST_FIXTURES"] == "1"
    private static let keyID = Data(repeating: 0x11, count: 32).base64EncodedString()
    private static let unix: TimeInterval = 1_700_000_000

    private final class Provider: AppAttestKeyProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var hashes: [Data] = []
        var assertedHashes: [Data] { lock.withLock { hashes } }
        var isSupported: Bool { true }
        func generateKey() async throws -> String { ShareLinkAttestContractTests.keyID }
        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { Data("attestation".utf8) }
        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
            lock.withLock { hashes.append(clientDataHash) }
            return Data("placeholder-assertion".utf8)
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(URL, [String: String], Data)] = []
        var all: [(URL, [String: String], Data)] { lock.withLock { sent } }
        func record(_ url: URL, _ headers: [String: String], _ body: Data) { lock.withLock { sent.append((url, headers, body)) } }
    }

    private func fixture(_ relative: String) throws -> URL {
        try TestInputs.url(.contracts, "fixtures/share-link-attest/\(relative)")
    }

    private func object(at url: URL) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary, url.lastPathComponent)
    }

    func testTheSenderCheckRequestMatchesTheRecordedOne() async throws {
        let name = "ShareLinkAttestContractTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = Provider(), recorder = Recorder()
        let client = AttestedServerClient(
            provider: provider, store: AppAttestKeyStore(defaults: defaults), consent: { true },
            server: { URL(string: "https://links.example.test\($0)")! },
            now: { Date(timeIntervalSince1970: Self.unix) }
        ) { url, headers, body in
            recorder.record(url, headers, body)
            switch url.path {
            case "/api/v1/attest/challenge": return (200, Data(#"{"challenge":"\#(Data(repeating: 1, count: 32).base64EncodedString())"}"#.utf8))
            case "/api/v1/attest/register": return (201, Data(#"{"registered":true}"#.utf8))
            default: return (200, Data(#"{"ok":true}"#.utf8))
            }
        }
        _ = try await client.send(path: ShareLinkSenderCheck.path, body: Data())

        let (url, headers, body) = try XCTUnwrap(recorder.all.first { $0.0.path == ShareLinkSenderCheck.path })
        let assertionHeader = "X-SM-Assertion"
        XCTAssertNotNil(headers[assertionHeader], "the assertion travels in its own header")
        let hash = try XCTUnwrap(provider.assertedHashes.last)
        let recorded: [String: Any] = [
            "method": "POST",
            "path": url.path,
            "time": Int(Self.unix),
            "bodyBase64": body.base64EncodedString(),
            "headers": headers.filter { $0.key != assertionHeader },
            "assertionHeader": assertionHeader,
            "clientDataSHA256": hash.map { String(format: "%02x", $0) }.joined(),
        ]
        let file = try fixture("requests/sender-check.json")
        if Self.regenerate {
            let data = try JSONSerialization.data(withJSONObject: recorded, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: file)
        }
        XCTAssertEqual(try object(at: file), recorded as NSDictionary,
                       "the app's attested request changed: the Go middleware test reads this file (SM_REGENERATE_ATTEST_FIXTURES=1 rewrites it)")
    }

    /// The real middleware's refusals, as the Go test recorded them, read by the app's mapping (#4134 1a).
    func testTheServersRefusalsMapToTheirReasons() throws {
        let rows: [(String, Int, ShareLinkUncheckedReason)] = [
            ("clock_skew", 401, .clockSkew),
            ("unknown_key", 401, .unknownKey),
            ("invalid_assertion", 401, .invalidAssertion),
            ("missing_assertion", 401, .missingAssertion),
        ]
        for (name, status, reason) in rows {
            let answer = try object(at: fixture("responses/\(name).json"))
            XCTAssertEqual(answer["status"] as? Int, status, name)
            let body = try JSONSerialization.data(withJSONObject: try XCTUnwrap(answer["body"]))
            XCTAssertEqual(ShareLinkSenderCheck.uncheckedReason(status: status, body: body), reason, name)
        }
    }

    /// The real middleware's 200 from the sender endpoint decodes as a standing with a permit (the permit and its expiry
    /// are placeholders: they are random per run).
    func testTheServersAllowedAnswerDecodes() throws {
        let answer = try object(at: fixture("responses/ok.json"))
        XCTAssertEqual(answer["status"] as? Int, 200)
        let body = try JSONSerialization.data(withJSONObject: try XCTUnwrap(answer["body"]))
        let standing = try XCTUnwrap(ShareLinkSenderCheck.decode(body))
        XCTAssertTrue(standing.sharingAllowed)
        XCTAssertFalse(standing.sharingEnded)
    }
}
