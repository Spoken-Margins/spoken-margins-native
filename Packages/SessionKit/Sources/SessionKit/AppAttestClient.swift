#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// The phone side of attested requests (#2239 step 2, research/B4/DESIGN.md section 2). The server asks one thing of
// an install that wants a feature with an identity attached (today: the sender check before a share link): prove
// you are the real app, with a key Apple certified. This file does the dance and nothing else; Apple's own calls
// sit behind `AppAttestKeyProvider`, so the rules below run on Linux against a fake.
//
// The rules, each one tested:
// - Nothing happens before the listener agreed (`ServerSendConsent`). Not the key, not the challenge, not a request.
//   The caller passes where the agreement is read from; there is no default, so no path can skip it (#2842).
// - The key is made lazily, on the first attested request, never at launch.
// - The key id lives in UserDefaults, never the Keychain: a Keychain item outlives deleting the app, so a reinstall
//   would carry the old key and link two installs (Apple agreement 3.3.3B). A reinstall asks for consent again and
//   attests a fresh key.
// - A server that no longer knows the key (`unknown_key`) gets one fresh attestation, then the request again.
// - A registration that failed after a key was made is remembered for this launch, with a backoff that doubles. While
//   attestation can't succeed (no entitlement, a development key against the production server) a Share tap would
//   otherwise orphan a Secure Enclave key and spend a server challenge each time, which Apple advises against (#4135).
//   During the wait `send` throws `.failed` without asking Apple or the server anything.

/// Apple's App Attest calls (`DCAppAttestService`), as the app implements them. A `DCAppAttestService` file must
/// itself check consent before it makes a key; `scripts/tests/test_server_contact_consent.py` fails if one doesn't.
public protocol AppAttestKeyProvider: Sendable {
    /// False in the Simulator and on the few devices without App Attest.
    var isSupported: Bool { get }
    /// A new Secure Enclave key; its id as base64, the way Apple returns it.
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// One POST, with the headers the caller chose. The real transport is host-pinned, ephemeral and follows no redirect.
public typealias AttestedPost = @Sendable (_ url: URL, _ headers: [String: String], _ body: Data) async throws -> (status: Int, body: Data)

/// Where the install's App Attest key id is kept: this app's UserDefaults, so deleting the app deletes it.
public final class AppAttestKeyStore: @unchecked Sendable {
    public static let defaultsKey = "appAttest.keyID.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var keyID: String? {
        defaults.string(forKey: Self.defaultsKey)
    }

    public func save(_ keyID: String) {
        defaults.set(keyID, forKey: Self.defaultsKey)
    }

    public func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

public enum AppAttestFailure: Error, Equatable, Sendable {
    /// The listener has not agreed. Nothing was made or sent.
    case needsConsent
    /// This phone can't attest (Simulator, older device). Nothing was sent.
    case unsupported
    /// The server refused this install (403). It does not say why.
    case refused
    /// The phone could not reach the server.
    case offline
    /// Apple's call failed, or the server answered something unexpected.
    case failed
    /// Apple has no key for the saved key id (`DCError.invalidKey`): the id came back from a backup or a new phone.
    /// This is the only signing failure that replaces the key; any other leaves the install's identity as it is.
    case keyUnusable
}

/// Makes requests the server can tie to a real install without learning who it is.
public final class AttestedServerClient: @unchecked Sendable {
    /// What the server signs over (`api.ClientData` in research/B4/server): method, path, time and the body's hash.
    static let clientDataPrefix = "spokenmargins-assertion-v1"
    static let challengePath = "/api/v1/attest/challenge"
    static let registerPath = "/api/v1/attest/register"

    private let provider: AppAttestKeyProvider
    private let store: AppAttestKeyStore
    private let hasConsent: @Sendable () -> Bool
    private let server: @Sendable (String) -> URL
    private let post: AttestedPost
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var registering: Task<String, Error>?
    /// Failed registrations since the last success, and when the next one may start (#4135). Memory only: a new launch
    /// tries once, so a fixed build or entitlement is picked up without waiting.
    private var registrationFailures = 0
    private var registrationRetryAfter: Date?
    static let registrationBackoffBase: TimeInterval = 10 * 60
    static let registrationBackoffCap: TimeInterval = 6 * 60 * 60

    /// `consent` has no default on purpose, as in `ShareLinkClient`.
    public init(
        provider: AppAttestKeyProvider,
        store: AppAttestKeyStore = AppAttestKeyStore(),
        consent: @escaping @Sendable () -> Bool,
        server: @escaping @Sendable (String) -> URL = { ProductServer.url(path: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        post: @escaping AttestedPost
    ) {
        self.provider = provider
        self.store = store
        self.hasConsent = consent
        self.server = server
        self.now = now
        self.post = post
    }

    /// Whether an attested request can be made on this phone at all. Asks nothing of Apple and sends nothing.
    public var isSupported: Bool { provider.isSupported }

    /// Sends one attested POST and returns the server's answer. Callers must not overlap sends: each assertion carries
    /// a counter the server requires to rise (the share screen makes one link at a time).
    public func send(path: String, body: Data) async throws -> (status: Int, body: Data) {
        // Before the key, the challenge or any request: the listener's agreement, then whether this phone can attest.
        guard hasConsent() else { throw AppAttestFailure.needsConsent }
        guard provider.isSupported else { throw AppAttestFailure.unsupported }
        var attestedAgain = false
        while true {
            let keyID = try await registeredKeyID()
            let response: (status: Int, body: Data)
            do {
                response = try await sendOnce(keyID: keyID, path: path, body: body)
            } catch is KeyUnusable {
                // A key id came back from a backup or a new phone, but the Secure Enclave key did not. Attest a new
                // one, once.
                guard !attestedAgain else { throw AppAttestFailure.failed }
                store.forget()
                attestedAgain = true
                continue
            }
            switch response.status {
            case 401 where Self.errorCode(response.body) == "unknown_key" && !attestedAgain:
                // The server lost this key (its records expire after 90 days). Attest a new one, once.
                store.forget()
                attestedAgain = true
            case 403:
                throw AppAttestFailure.refused
            default:
                return response
            }
        }
    }

    // MARK: Registration

    private func registeredKeyID() async throws -> String {
        if let saved = store.keyID { return saved }
        let task: Task<String, Error> = try lock.withLock {
            if let registering { return registering }
            // A request that joins a registration already running shares its outcome; only a new one waits out a failure.
            if let retryAfter = registrationRetryAfter, now() < retryAfter { throw AppAttestFailure.failed }
            let created = Task { try await self.register() }
            registering = created
            return created
        }
        defer { lock.withLock { registering = nil } }
        return try await task.value
    }

    private func register() async throws -> String {
        // The challenge comes first: with no challenge there is nothing to attest, and a failure here has made no key.
        let challengeAnswer = try await transport(server(Self.challengePath), [:], Data())
        guard challengeAnswer.status == 200,
              let challenge = try? JSONDecoder().decode(Challenge.self, from: challengeAnswer.body),
              let challengeBytes = Data(base64Encoded: challenge.challenge), !challengeBytes.isEmpty else {
            throw AppAttestFailure.failed
        }
        let keyID: String
        let attestation: Data
        do {
            keyID = try await provider.generateKey()
            // The server checks Apple's certificate against SHA-256 of its own challenge.
            attestation = try await provider.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: challengeBytes)))
        } catch {
            noteRegistrationFailed()
            throw AppAttestFailure.failed
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "keyId": keyID,
            "challenge": challenge.challenge,
            "attestation": attestation.base64EncodedString()
        ], options: [.sortedKeys])
        // From here a key exists, so any failure orphans it: remember it, offline included.
        let registered: (status: Int, body: Data)
        do {
            registered = try await transport(server(Self.registerPath), ["Content-Type": "application/json"], body)
        } catch {
            noteRegistrationFailed()
            throw error
        }
        // The key is kept only once the server has accepted it; a key it never saw would fail every request.
        guard registered.status == 201 else {
            noteRegistrationFailed()
            throw AppAttestFailure.failed
        }
        store.save(keyID)
        lock.withLock {
            registrationFailures = 0
            registrationRetryAfter = nil
        }
        return keyID
    }

    /// A key was made and could not be registered. The next registration waits 10 minutes, then 20, 40, up to 6 hours.
    private func noteRegistrationFailed() {
        lock.withLock {
            registrationFailures += 1
            let wait = min(Self.registrationBackoffBase * pow(2, Double(min(registrationFailures - 1, 20))), Self.registrationBackoffCap)
            registrationRetryAfter = now().addingTimeInterval(wait)
        }
    }

    /// Apple says it has no key for the saved key id.
    private struct KeyUnusable: Error {}

    private struct Challenge: Decodable {
        var challenge: String
    }

    // MARK: Requests

    private func sendOnce(keyID: String, path: String, body: Data) async throws -> (status: Int, body: Data) {
        let unix = Int64(now().timeIntervalSince1970)
        let clientData = Self.clientData(method: "POST", path: path, unix: unix, body: body)
        let assertion: Data
        do {
            assertion = try await provider.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: clientData)))
        } catch AppAttestFailure.keyUnusable {
            throw KeyUnusable()
        } catch {
            // A one-off Apple error is not a lost key: replacing the key here would hand a paused sender a clean
            // standing under a new identity.
            throw AppAttestFailure.failed
        }
        let headers = [
            "Content-Type": "application/json",
            "X-SM-Key-Id": keyID,
            "X-SM-Assertion": assertion.base64EncodedString(),
            "X-SM-Time": String(unix)
        ]
        return try await transport(server(path), headers, body)
    }

    private func transport(_ url: URL, _ headers: [String: String], _ body: Data) async throws -> (status: Int, body: Data) {
        do {
            return try await post(url, headers, body)
        } catch {
            throw AppAttestFailure.offline
        }
    }

    /// The exact bytes the server verifies: `api.ClientData` in research/B4/server/internal/api/api.go.
    static func clientData(method: String, path: String, unix: Int64, body: Data) -> Data {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data([clientDataPrefix, method, path, String(unix), digest].joined(separator: "\n").utf8)
    }

    static func errorCode(_ body: Data) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
    }
}
