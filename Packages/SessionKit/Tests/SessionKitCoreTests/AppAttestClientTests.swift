#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit

/// The phone side of attested requests (#2239 step 2). Apple's calls are a fake; the server is a recording one that
/// answers like `research/B4/server/internal/api` (challenge, register, an attested endpoint).
final class AppAttestClientTests: XCTestCase {
    private final class Provider: AppAttestKeyProvider, @unchecked Sendable {
        private let lock = NSLock()
        let supported: Bool
        private(set) var keysMade = 0
        private(set) var attestedHashes: [Data] = []
        private(set) var assertedHashes: [Data] = []
        var failAttest = false
        init(supported: Bool = true) { self.supported = supported }
        var isSupported: Bool { supported }
        func generateKey() async throws -> String {
            lock.withLock { keysMade += 1; return Data(repeating: UInt8(keysMade), count: 32).base64EncodedString() }
        }
        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
            try lock.withLock {
                if failAttest { throw URLError(.cancelled) }
                attestedHashes.append(clientDataHash)
            }
            return Data("attestation-of-\(keyID)".utf8)
        }
        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
            lock.withLock { assertedHashes.append(clientDataHash) }
            return Data("assertion".utf8)
        }
        var counts: (keys: Int, attested: Int, asserted: Int) { lock.withLock { (keysMade, attestedHashes.count, assertedHashes.count) } }
    }

    private struct Sent { var path: String; var headers: [String: String]; var body: Data }

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sent: [Sent] = []
        let challenge = Data((0..<32).map { UInt8(200 - $0) })
        var registerStatus = 201
        /// Statuses the attested endpoint answers in turn; the last one repeats.
        var answers: [(Int, String)] = [(200, #"{"ok":true}"#)]
        var offline = false
        func handle(_ url: URL, _ headers: [String: String], _ body: Data) async throws -> (status: Int, body: Data) {
            let index: Int = try lock.withLock {
                if offline { throw URLError(.notConnectedToInternet) }
                sent.append(Sent(path: url.path, headers: headers, body: body))
                return sent.filter { $0.path == "/api/v1/links/sender" }.count - 1
            }
            switch url.path {
            case "/api/v1/attest/challenge": return (200, Data(#"{"challenge":"\#(challenge.base64EncodedString())","expiresInSeconds":300}"#.utf8))
            case "/api/v1/attest/register": return (registerStatus, Data(#"{"registered":true}"#.utf8))
            default:
                let answer = answers[min(index, answers.count - 1)]
                return (answer.0, Data(answer.1.utf8))
            }
        }
        func paths() -> [String] { lock.withLock { sent.map(\.path) } }
        func all() -> [Sent] { lock.withLock { sent } }
    }

    private func defaults() -> UserDefaults {
        let name = "AppAttestClientTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func client(_ provider: Provider, _ server: Server, store: AppAttestKeyStore, consent: Bool = true) -> AttestedServerClient {
        AttestedServerClient(
            provider: provider, store: store, consent: { consent },
            server: { URL(string: "https://links.example.test\($0)")! },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            post: { url, headers, body in try await server.handle(url, headers, body) }
        )
    }

    func testWithoutConsentNothingIsAskedOfAppleOrTheServer() async {
        let provider = Provider(supported: false), server = Server()
        let store = AppAttestKeyStore(defaults: defaults())
        do {
            _ = try await client(provider, server, store: store, consent: false).send(path: "/api/v1/links/sender", body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .needsConsent, "consent is asked before support: nothing is touched")
        }
        XCTAssertEqual(provider.counts.keys, 0)
        XCTAssertEqual(server.paths(), [])
        XCTAssertNil(store.keyID)
    }

    func testAPhoneThatCannotAttestMakesNoKeyAndSendsNothing() async {
        let provider = Provider(supported: false), server = Server()
        let store = AppAttestKeyStore(defaults: defaults())
        do {
            _ = try await client(provider, server, store: store).send(path: "/api/v1/links/sender", body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .unsupported)
        }
        XCTAssertEqual(provider.counts.keys, 0)
        XCTAssertEqual(server.paths(), [])
    }

    func testTheFirstRequestRegistersTheKeyThenSignsAndLaterOnesReuseIt() async throws {
        let provider = Provider(), server = Server()
        let store = AppAttestKeyStore(defaults: defaults())
        let attested = client(provider, server, store: store)

        let first = try await attested.send(path: "/api/v1/links/sender", body: Data())
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(server.paths(), ["/api/v1/attest/challenge", "/api/v1/attest/register", "/api/v1/links/sender"])

        // Apple certifies the key against SHA-256 of the server's own challenge, which the server recomputes.
        XCTAssertEqual(provider.attestedHashes, [Data(SHA256.hash(data: server.challenge))])
        let keyID = try XCTUnwrap(store.keyID)
        let register = try XCTUnwrap(try JSONSerialization.jsonObject(with: server.all()[1].body) as? [String: String])
        XCTAssertEqual(register["keyId"], keyID)
        XCTAssertEqual(register["challenge"], server.challenge.base64EncodedString())
        XCTAssertEqual(register["attestation"], Data("attestation-of-\(keyID)".utf8).base64EncodedString())
        XCTAssertEqual(Set(register.keys), ["keyId", "challenge", "attestation"])

        let headers = server.all()[2].headers
        XCTAssertEqual(headers["X-SM-Key-Id"], keyID)
        XCTAssertEqual(headers["X-SM-Assertion"], Data("assertion".utf8).base64EncodedString())
        XCTAssertEqual(headers["X-SM-Time"], "1700000000")

        _ = try await attested.send(path: "/api/v1/links/sender", body: Data())
        XCTAssertEqual(provider.counts.keys, 1, "one key per install")
        XCTAssertEqual(provider.counts.asserted, 2)
        XCTAssertEqual(server.paths().filter { $0.hasSuffix("/register") }.count, 1)
    }

    /// The bytes the Go server verifies (`api.ClientData`): the same five lines, the body hashed as lowercase hex.
    func testTheSignedBytesAreTheOnesTheServerChecks() {
        let empty = AttestedServerClient.clientData(method: "POST", path: "/api/v1/links/sender", unix: 1_700_000_000, body: Data())
        XCTAssertEqual(
            String(decoding: empty, as: UTF8.self),
            "spokenmargins-assertion-v1\nPOST\n/api/v1/links/sender\n1700000000\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        let body = AttestedServerClient.clientData(method: "POST", path: "/p", unix: 5, body: Data("abc".utf8))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasSuffix("\nba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    }

    func testTheAssertionIsOverTheRequestItSigns() async throws {
        let provider = Provider(), server = Server()
        _ = try await client(provider, server, store: AppAttestKeyStore(defaults: defaults())).send(path: "/api/v1/links/sender", body: Data("{}".utf8))
        let expected = AttestedServerClient.clientData(method: "POST", path: "/api/v1/links/sender", unix: 1_700_000_000, body: Data("{}".utf8))
        XCTAssertEqual(provider.assertedHashes, [Data(SHA256.hash(data: expected))])
    }

    func testAKeyTheServerRefusedIsNeverKept() async {
        let provider = Provider(), server = Server()
        server.registerStatus = 401
        let store = AppAttestKeyStore(defaults: defaults())
        do {
            _ = try await client(provider, server, store: store).send(path: "/api/v1/links/sender", body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .failed)
        }
        XCTAssertNil(store.keyID, "a key the server never accepted would fail every later request")
        XCTAssertFalse(server.paths().contains("/api/v1/links/sender"))
    }

    func testAnAppleFailureIsAFailureAndLeavesNoKey() async {
        let provider = Provider(), server = Server()
        provider.failAttest = true
        let store = AppAttestKeyStore(defaults: defaults())
        do {
            _ = try await client(provider, server, store: store).send(path: "/api/v1/links/sender", body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .failed)
        }
        XCTAssertNil(store.keyID)
        XCTAssertFalse(server.paths().contains("/api/v1/attest/register"))
    }

    func testAServerThatForgotTheKeyGetsOneFreshAttestationAndTheRequestAgain() async throws {
        let provider = Provider(), server = Server()
        server.answers = [(401, #"{"error":"unknown_key"}"#), (200, #"{"ok":true}"#)]
        let store = AppAttestKeyStore(defaults: defaults())
        store.save(Data(repeating: 9, count: 32).base64EncodedString())
        let answer = try await client(provider, server, store: store).send(path: "/api/v1/links/sender", body: Data())
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(provider.counts.keys, 1)
        XCTAssertNotEqual(store.keyID, Data(repeating: 9, count: 32).base64EncodedString())
        XCTAssertEqual(server.paths(), ["/api/v1/links/sender", "/api/v1/attest/challenge", "/api/v1/attest/register", "/api/v1/links/sender"])
    }

    func testAServerThatKeepsForgettingIsAskedOnlyOnce() async throws {
        let provider = Provider(), server = Server()
        server.answers = [(401, #"{"error":"unknown_key"}"#)]
        let answer = try await client(provider, server, store: AppAttestKeyStore(defaults: defaults())).send(path: "/api/v1/links/sender", body: Data())
        XCTAssertEqual(answer.status, 401)
        XCTAssertEqual(provider.counts.keys, 2, "one attestation for the first request, one after the server said unknown_key")
    }

    func testABlockedInstallIsRefusedAndNothingMoreIsTried() async {
        let provider = Provider(), server = Server()
        server.answers = [(403, #"{"error":"refused"}"#)]
        do {
            _ = try await client(provider, server, store: AppAttestKeyStore(defaults: defaults())).send(path: "/api/v1/links/sender", body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .refused)
        }
        XCTAssertEqual(provider.counts.keys, 1)
    }

    func testNoNetworkIsOffline() async {
        let provider = Provider(), server = Server()
        server.offline = true
        let store = AppAttestKeyStore(defaults: defaults())
        do {
            _ = try await client(provider, server, store: store).send(path: "/api/v1/links/sender", body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .offline)
        }
        XCTAssertEqual(provider.counts.keys, 0, "no challenge, so no key was made")
        XCTAssertNil(store.keyID)
    }

    /// A reinstall empties UserDefaults, so the new install has no key id and makes its own; nothing carries over
    /// (Apple agreement 3.3.3B). Two empty stores stand for two installs.
    func testAReinstallMakesAFreshKeyThatSharesNothingWithTheOldOne() async throws {
        let provider = Provider(), server = Server()
        let before = AppAttestKeyStore(defaults: defaults())
        _ = try await client(provider, server, store: before).send(path: "/api/v1/links/sender", body: Data())
        let after = AppAttestKeyStore(defaults: defaults())
        XCTAssertNil(after.keyID)
        _ = try await client(provider, server, store: after).send(path: "/api/v1/links/sender", body: Data())
        XCTAssertNotNil(after.keyID)
        XCTAssertNotEqual(before.keyID, after.keyID)
        XCTAssertEqual(provider.counts.keys, 2)
    }

    func testTwoRequestsStartedTogetherRegisterOneKey() async throws {
        let provider = Provider(), server = Server()
        let attested = client(provider, server, store: AppAttestKeyStore(defaults: defaults()))
        async let one = attested.send(path: "/api/v1/links/sender", body: Data())
        async let two = attested.send(path: "/api/v1/links/sender", body: Data())
        _ = try await (one, two)
        XCTAssertEqual(provider.counts.keys, 1)
        XCTAssertEqual(server.paths().filter { $0.hasSuffix("/register") }.count, 1)
    }
}
