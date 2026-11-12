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
        /// A one-off Apple error while signing, with the key itself fine.
        var failAssertion = false
        /// Key ids Apple has no key for (a key id restored from a backup).
        var unknownToApple: Set<String> = []
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
            try lock.withLock {
                if unknownToApple.contains(keyID) { throw AppAttestFailure.keyUnusable }
                if failAssertion { throw URLError(.cancelled) }
                assertedHashes.append(clientDataHash)
            }
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

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 1_700_000_000
        var date: Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
        func advance(_ by: TimeInterval) { lock.withLock { seconds += by } }
    }

    private func client(_ provider: Provider, _ server: Server, store: AppAttestKeyStore, consent: Bool = true, clock: Clock = Clock()) -> AttestedServerClient {
        AttestedServerClient(
            provider: provider, store: store, consent: { consent },
            server: { URL(string: "https://links.example.test\($0)")! },
            now: { clock.date },
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

    /// UserDefaults comes back from a backup or to a new phone; the Secure Enclave key does not.
    func testAKeyIdRestoredFromABackupIsReplacedWhenAppleHasNoKeyForIt() async throws {
        let provider = Provider(), server = Server()
        let restored = Data(repeating: 9, count: 32).base64EncodedString()
        provider.unknownToApple = [restored]
        let store = AppAttestKeyStore(defaults: defaults())
        store.save(restored)
        let answer = try await client(provider, server, store: store).send(path: "/api/v1/links/sender", body: Data())
        XCTAssertEqual(answer.status, 200)
        XCTAssertNotEqual(store.keyID, restored)
        XCTAssertEqual(provider.counts.keys, 1)
    }

    /// A paused sender must not shed its standing by a transient Apple error: the key stays, the request fails.
    func testAOneOffAppleErrorWhileSigningKeepsTheKeyAndTheIdentity() async throws {
        let provider = Provider(), server = Server()
        let store = AppAttestKeyStore(defaults: defaults())
        let attested = client(provider, server, store: store)
        _ = try await attested.send(path: "/api/v1/links/sender", body: Data())
        let kept = try XCTUnwrap(store.keyID)
        provider.failAssertion = true
        do {
            _ = try await attested.send(path: "/api/v1/links/sender", body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .failed)
        }
        XCTAssertEqual(store.keyID, kept)
        XCTAssertEqual(provider.counts.keys, 1, "no new identity was made")
    }

    func testAnAssertionThatKeepsFailingIsAFailureNotALoop() async {
        let provider = Provider(), server = Server()
        let store = AppAttestKeyStore(defaults: defaults())
        provider.unknownToApple = Set([1, 2, 3].map { Data(repeating: $0, count: 32).base64EncodedString() })
        do {
            _ = try await client(provider, server, store: store).send(path: "/api/v1/links/sender", body: Data())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .failed)
        }
        XCTAssertEqual(provider.counts.keys, 2, "one fresh key after the first failed to sign, then it stops")
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

    // MARK: A failed registration is remembered (#4135)

    private func tap(_ attested: AttestedServerClient) async -> AppAttestFailure? {
        do {
            _ = try await attested.send(path: "/api/v1/links/sender", body: Data())
            return nil
        } catch {
            return error as? AppAttestFailure
        }
    }

    /// Attestation that can't succeed (no entitlement, a development key against the production server): the second and
    /// third Share tap must not mint another key or ask for another challenge.
    func testARegistrationThatFailedIsNotRetriedOnEveryTap() async {
        let provider = Provider(), server = Server()
        provider.failAttest = true
        let attested = client(provider, server, store: AppAttestKeyStore(defaults: defaults()))
        for _ in 0..<3 { let failure = await tap(attested); XCTAssertEqual(failure, .failed) }
        XCTAssertEqual(provider.counts.keys, 1, "one orphaned key, not three")
        XCTAssertEqual(server.paths().filter { $0.hasSuffix("/challenge") }.count, 1, "one challenge spent, not three")
    }

    func testAServerRefusalOfTheKeyIsRememberedToo() async {
        let provider = Provider(), server = Server()
        server.registerStatus = 401
        let attested = client(provider, server, store: AppAttestKeyStore(defaults: defaults()))
        for _ in 0..<3 { let failure = await tap(attested); XCTAssertEqual(failure, .failed) }
        XCTAssertEqual(provider.counts.keys, 1)
        XCTAssertEqual(server.paths().filter { $0.hasSuffix("/register") }.count, 1)
    }

    /// The wait doubles: 10 minutes after the first failure, 20 after the second, so a phone that can never attest
    /// costs a key every few hours at most, not one per tap.
    func testTheWaitDoublesAndNothingIsTriedBeforeItEnds() async {
        let provider = Provider(), server = Server()
        provider.failAttest = true
        let clock = Clock()
        let attested = client(provider, server, store: AppAttestKeyStore(defaults: defaults()), clock: clock)
        _ = await tap(attested)
        XCTAssertEqual(provider.counts.keys, 1)
        clock.advance(AttestedServerClient.registrationBackoffBase - 1)
        _ = await tap(attested)
        XCTAssertEqual(provider.counts.keys, 1, "still waiting, a second before the first wait ends")
        clock.advance(1)
        _ = await tap(attested)
        XCTAssertEqual(provider.counts.keys, 2, "the first wait is over: one more try")
        clock.advance(AttestedServerClient.registrationBackoffBase)
        _ = await tap(attested)
        XCTAssertEqual(provider.counts.keys, 2, "the second wait is twice as long")
        clock.advance(AttestedServerClient.registrationBackoffBase)
        _ = await tap(attested)
        XCTAssertEqual(provider.counts.keys, 3)
    }

    func testTheWaitHasACap() async {
        let provider = Provider(), server = Server()
        provider.failAttest = true
        let clock = Clock()
        let attested = client(provider, server, store: AppAttestKeyStore(defaults: defaults()), clock: clock)
        for _ in 0..<30 {
            _ = await tap(attested)
            clock.advance(AttestedServerClient.registrationBackoffCap)
        }
        XCTAssertEqual(provider.counts.keys, 30, "after a cap's wait the next tap always tries, however many failures came before")
    }

    func testARegistrationThatWorksAfterTheWaitClearsIt() async throws {
        let provider = Provider(), server = Server()
        provider.failAttest = true
        let clock = Clock()
        let store = AppAttestKeyStore(defaults: defaults())
        let attested = client(provider, server, store: store, clock: clock)
        _ = await tap(attested)
        provider.failAttest = false
        let during = await tap(attested)
        XCTAssertEqual(during, .failed, "the wait holds even though Apple would now succeed")
        clock.advance(AttestedServerClient.registrationBackoffBase)
        let answer = try await attested.send(path: "/api/v1/links/sender", body: Data())
        XCTAssertEqual(answer.status, 200)
        XCTAssertNotNil(store.keyID)
        // A later lost key attests at once: the earlier failure no longer counts.
        store.forget()
        let again = try await attested.send(path: "/api/v1/links/sender", body: Data())
        XCTAssertEqual(again.status, 200)
    }

    /// No key was made, so there is nothing to protect: a phone that is only offline retries on the next tap.
    func testBeingOfflineBeforeAnyKeyExistsIsNotRemembered() async {
        let provider = Provider(), server = Server()
        server.offline = true
        let attested = client(provider, server, store: AppAttestKeyStore(defaults: defaults()))
        let first = await tap(attested), second = await tap(attested)
        XCTAssertEqual(first, .offline)
        XCTAssertEqual(second, .offline)
        server.offline = false
        let third = await tap(attested)
        XCTAssertNil(third)
        XCTAssertEqual(provider.counts.keys, 1)
    }

    /// The wait is only for making a new key: a request with a registered key signs and goes, whatever failed before.
    func testTheWaitDoesNotTouchAKeyThatIsAlreadyRegistered() async throws {
        let provider = Provider(), server = Server()
        let store = AppAttestKeyStore(defaults: defaults())
        let attested = client(provider, server, store: store)
        _ = try await attested.send(path: "/api/v1/links/sender", body: Data())
        provider.failAttest = true
        store.forget()
        _ = await tap(attested)
        store.save(Data(repeating: 1, count: 32).base64EncodedString())
        let answer = try await attested.send(path: "/api/v1/links/sender", body: Data())
        XCTAssertEqual(answer.status, 200, "a saved key never waits")
    }
}
