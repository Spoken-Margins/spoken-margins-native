#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// One real App Attest attestation and assertion, saved as the file #1593's verifier test reads (#4818).
//
// Every other test of the server's verifier runs against `fakeattest`, which was written from the same reading of
// Apple's documentation as the verifier, so a misreading they share is invisible to both. This is the one piece that
// meets bytes Apple produced: a phone build offers a button (Settings > Diagnostics, `SM_APP_ATTEST_CAPTURE`), the
// button runs `AppAttestDeviceCaptureRunner`, and the owner puts the JSON it shares at
// `research/B4/server/internal/appattest/testdata/device-capture.json`.
//
// What it does not do, each one tested: it sends nothing to any server (the challenge is local random bytes, and the
// runner holds no transport at all), it keeps no key id (it never touches `AppAttestKeyStore`), and it makes no key
// before the listener's agreement is on record, the rule `AppAttestDeviceProvider` applies to every Apple call.

/// The file, field for field as `deviceCapture` in `research/B4/server/internal/appattest/device_capture_test.go`
/// reads it. `AppAttestDeviceCaptureTests` fails if the two ever differ.
public struct AppAttestDeviceCapture: Codable, Equatable, Sendable {
    public struct Assertion: Codable, Equatable, Sendable {
        /// The bytes passed to `generateAssertion` before hashing, base64.
        public var clientData: String
        /// The CBOR object from `generateAssertion`, base64.
        public var assertion: String
        /// The counter the key had before this assertion: 0, because the key is new.
        public var counterBefore: UInt32

        public init(clientData: String, assertion: String, counterBefore: UInt32) {
            self.clientData = clientData
            self.assertion = assertion
            self.counterBefore = counterBefore
        }
    }

    /// `<team id>.<bundle id>`, the way Apple hashes it into the attestation.
    public var appId: String
    /// `development` or `production`: which App Attest environment the build is entitled to.
    public var environment: String
    /// A time inside the leaf certificate's validity: the moment of capture, RFC 3339 in UTC.
    public var verifyAt: String
    /// Apple's key id, base64.
    public var keyId: String
    /// The challenge bytes the server would have sent, base64. Here they are random and local.
    public var challenge: String
    /// The CBOR object from `attestKey`, base64.
    public var attestation: String
    public var assertion: Assertion

    public init(
        appId: String, environment: String, verifyAt: String, keyId: String, challenge: String, attestation: String,
        assertion: Assertion
    ) {
        self.appId = appId
        self.environment = environment
        self.verifyAt = verifyAt
        self.keyId = keyId
        self.challenge = challenge
        self.attestation = attestation
        self.assertion = assertion
    }

    /// The file's name, which the Go test looks for under `testdata/`.
    public static let fileName = "device-capture.json"

    /// The JSON as the owner saves it: readable, with the fields in a fixed order so two captures diff cleanly.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum AppAttestCaptureFailure: Error, Equatable, Sendable {
    /// The build did not say its App ID or environment, or said one the verifier would not accept. Nothing was made.
    /// The reason names what is wrong, never the value.
    case buildDescriptionMissing(String)
}

/// Makes the capture on the phone. Apple's calls sit behind `AppAttestKeyProvider`, so the rules run on Linux against a
/// fake, and the app passes the same `AppAttestDeviceProvider` the sender check uses.
public struct AppAttestDeviceCaptureRunner: Sendable {
    /// What the assertion is made over. Fixed, so a capture is the same shape every time; the server's real client data
    /// is built by `AttestedServerClient.clientData`, and the verifier does not care what the bytes say.
    public static let clientData = Data("spokenmargins-device-capture-v1".utf8)
    public static let challengeByteCount = 32

    private let provider: AppAttestKeyProvider
    private let hasConsent: @Sendable () -> Bool
    private let appID: String
    private let environment: String
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) -> Data

    /// `consent` has no default on purpose, as in `AttestedServerClient`.
    /// - Parameters:
    ///   - appID: `<team id>.<bundle id>`; the build writes it into Info.plist.
    ///   - environment: `development` or `production`, from the build setting that also sets the entitlement.
    public init(
        provider: AppAttestKeyProvider,
        consent: @escaping @Sendable () -> Bool,
        appID: String,
        environment: String,
        now: @escaping @Sendable () -> Date = { Date() },
        randomBytes: @escaping @Sendable (Int) -> Data = { count in
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        }
    ) {
        self.provider = provider
        self.hasConsent = consent
        self.appID = appID
        self.environment = environment
        self.now = now
        self.randomBytes = randomBytes
    }

    /// Whether `appID` looks like `<10-character team id>.<bundle id>`. A build with no signing team writes
    /// `.com.spokenmargins.native`, which would make a capture the verifier can never accept.
    static func isValidAppID(_ appID: String) -> Bool {
        let parts = appID.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 10, parts[1].contains("."), !parts[1].hasPrefix(".") else { return false }
        return parts[0].allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// A fresh key, one attestation of a local challenge, one assertion over `clientData`. The key id is returned in the
    /// file and kept nowhere else.
    public func capture() async throws -> AppAttestDeviceCapture {
        // Before the key: the listener's agreement, then whether this phone can attest, then whether the file would be
        // one the verifier could use. A failure on any of them has made no key.
        guard hasConsent() else { throw AppAttestFailure.needsConsent }
        guard provider.isSupported else { throw AppAttestFailure.unsupported }
        guard Self.isValidAppID(appID) else { throw AppAttestCaptureFailure.buildDescriptionMissing("appId") }
        guard environment == "development" || environment == "production" else {
            throw AppAttestCaptureFailure.buildDescriptionMissing("environment")
        }

        let challenge = randomBytes(Self.challengeByteCount)
        guard challenge.count == Self.challengeByteCount else { throw AppAttestFailure.failed }

        let keyID = try await provider.generateKey()
        // The server checks Apple's certificate against SHA-256 of its challenge (`appattest.VerifyAttestation`).
        let attestation = try await provider.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: challenge)))
        let assertion = try await provider.generateAssertion(
            keyID, clientDataHash: Data(SHA256.hash(data: Self.clientData)))

        return AppAttestDeviceCapture(
            appId: appID,
            environment: environment,
            verifyAt: Self.timestamp(now()),
            keyId: keyID,
            challenge: challenge.base64EncodedString(),
            attestation: attestation.base64EncodedString(),
            assertion: .init(
                clientData: Self.clientData.base64EncodedString(),
                assertion: assertion.base64EncodedString(),
                counterBefore: 0))
    }

    /// What the capture button tells the owner when `capture()` threw. Plain words, no stack; an Apple error keeps its own
    /// description, since "the operation couldn't be completed" with a DeviceCheck code is what he would look up.
    public static func failureMessage(for error: Error) -> String {
        switch error {
        case AppAttestFailure.needsConsent:
            return "Nothing was made. Agree to the sender check first: make a share link once, then try again."
        case AppAttestFailure.unsupported:
            return "This device can't use App Attest. The Simulator and a few older phones can't."
        case AppAttestCaptureFailure.buildDescriptionMissing(let field):
            return "This build doesn't know its \(field), so a capture would not be one the verifier accepts. "
                + "Build with your signing team set in Config/Local.xcconfig."
        default:
            return "Apple's App Attest failed: \(error.localizedDescription) "
                + "If this is the first build with the App Attest entitlement, check that App Attest is switched on "
                + "for the App ID on Apple's developer site."
        }
    }

    /// RFC 3339 in UTC to the second, the form the Go test parses with `time.RFC3339`.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
