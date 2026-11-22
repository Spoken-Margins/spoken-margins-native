#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import SessionKitTestInputs
import XCTest
@testable import SessionKit

/// The one-tap App Attest capture (#4818): what the file says, that its field names are the Go test's, and that making
/// it sends nothing, keeps nothing and asks Apple nothing before the listener has agreed.
final class AppAttestDeviceCaptureTests: XCTestCase {
    private final class Provider: AppAttestKeyProvider, @unchecked Sendable {
        private let lock = NSLock()
        let supported: Bool
        private(set) var calls: [String] = []
        private(set) var attestedHash: Data?
        private(set) var assertedHash: Data?
        var failAttest = false
        init(supported: Bool = true) { self.supported = supported }
        var isSupported: Bool { supported }
        func generateKey() async throws -> String {
            lock.withLock { calls.append("generateKey") }
            return Data(repeating: 7, count: 32).base64EncodedString()
        }
        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
            try lock.withLock {
                calls.append("attestKey")
                if failAttest { throw URLError(.cancelled) }
                attestedHash = clientDataHash
            }
            return Data("attestation-of-\(keyID)".utf8)
        }
        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
            lock.withLock { calls.append("generateAssertion"); assertedHash = clientDataHash }
            return Data("assertion".utf8)
        }
        var made: [String] { lock.withLock { calls } }
    }

    private let appID = "J8SWC6J3VY.com.spokenmargins.native"
    private let moment = Date(timeIntervalSince1970: 1_791_000_000)  // 2026-10-03T04:00:00Z

    private func runner(
        _ provider: Provider, consent: Bool = true, appID: String? = nil, environment: String = "development"
    ) -> AppAttestDeviceCaptureRunner {
        AppAttestDeviceCaptureRunner(
            provider: provider, consent: { consent }, appID: appID ?? self.appID, environment: environment,
            now: { [moment] in moment }, randomBytes: { Data((0..<$0).map { UInt8($0 + 1) }) })
    }

    // MARK: the file

    func testTheCaptureCarriesWhatAppleReturnedAndHowItWasMade() async throws {
        let provider = Provider()
        let capture = try await runner(provider).capture()

        let challenge = Data((0..<32).map { UInt8($0 + 1) })
        XCTAssertEqual(provider.made, ["generateKey", "attestKey", "generateAssertion"])
        XCTAssertEqual(capture.appId, appID)
        XCTAssertEqual(capture.environment, "development")
        XCTAssertEqual(capture.verifyAt, "2026-10-03T04:00:00Z")
        XCTAssertEqual(capture.keyId, Data(repeating: 7, count: 32).base64EncodedString())
        XCTAssertEqual(capture.challenge, challenge.base64EncodedString())
        XCTAssertEqual(Data(base64Encoded: capture.attestation), Data("attestation-of-\(capture.keyId)".utf8))
        XCTAssertEqual(Data(base64Encoded: capture.assertion.assertion), Data("assertion".utf8))
        XCTAssertEqual(Data(base64Encoded: capture.assertion.clientData), AppAttestDeviceCaptureRunner.clientData)
        XCTAssertEqual(capture.assertion.counterBefore, 0)
        // The two hashes are what the Go verifier recomputes: SHA-256 of the challenge, SHA-256 of the client data.
        XCTAssertEqual(provider.attestedHash, Data(SHA256.hash(data: challenge)))
        XCTAssertEqual(provider.assertedHash, Data(SHA256.hash(data: AppAttestDeviceCaptureRunner.clientData)))
    }

    func testTwoCapturesDrawTwoChallenges() async throws {
        let provider = Provider()
        let live = AppAttestDeviceCaptureRunner(provider: provider, consent: { true }, appID: appID, environment: "development")
        let first = try await live.capture()
        let second = try await live.capture()
        XCTAssertNotEqual(first.challenge, second.challenge)
        XCTAssertEqual(Data(base64Encoded: first.challenge)?.count, 32)
    }

    func testTheTimestampIsRFC3339InUTCTheGoTestParses() {
        let table: [(Double, String)] = [
            (0, "1970-01-01T00:00:00Z"),
            (1_791_000_000, "2026-10-03T04:00:00Z"),
            (1_791_000_000.9, "2026-10-03T04:00:00Z"),  // fractions are dropped, never rounded up past the certificate
        ]
        for (seconds, expected) in table {
            XCTAssertEqual(AppAttestDeviceCaptureRunner.timestamp(Date(timeIntervalSince1970: seconds)), expected)
        }
    }

    // MARK: field names match the Go test

    /// The names in `deviceCapture` (and its inner assertion struct), read from the Go source the verifier test uses. A
    /// file whose names differ is skipped by nothing and parsed by nothing: the Go test would read zero values and fail
    /// far from the cause.
    func testExportedFieldNamesAreTheGoTestsStructTags() async throws {
        let goSource = try TestInputs.text(.research, "B4/server/internal/appattest/device_capture_test.go")
        let (outer, inner) = try Self.goTags(in: goSource)
        XCTAssertFalse(outer.isEmpty)
        XCTAssertFalse(inner.isEmpty)

        let capture = try await runner(Provider()).capture()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: capture.jsonData()) as? [String: Any])
        let assertion = try XCTUnwrap(object["assertion"] as? [String: Any])
        XCTAssertEqual(Set(object.keys), outer, "top-level names differ from `deviceCapture`")
        XCTAssertEqual(Set(assertion.keys), inner, "assertion names differ from `deviceCapture.Assertion`")
        XCTAssertEqual(object["environment"] as? String, "development")
        XCTAssertEqual(assertion["counterBefore"] as? Int, 0)
    }

    func testGoTagReaderSeesTheFieldsAndNotTheCommentExample() throws {
        let source = """
            //	  "appId": "x",  // the comment's example is not a tag
            type deviceCapture struct {
            	AppID       string `json:"appId"`
            	Assertion   struct {
            		ClientData    string `json:"clientData"`
            		CounterBefore uint32 `json:"counterBefore"`
            	} `json:"assertion"`
            }
            """
        let (outer, inner) = try Self.goTags(in: source)
        XCTAssertEqual(outer, ["appId", "assertion"])
        XCTAssertEqual(inner, ["clientData", "counterBefore"])
        XCTAssertThrowsError(try Self.goTags(in: "package x"))
    }

    /// Tags directly inside `deviceCapture` (including the `assertion` field that closes the inner struct) and tags inside its
    /// inner `Assertion struct { ... }`.
    private static func goTags(in source: String) throws -> (outer: Set<String>, inner: Set<String>) {
        guard let start = source.range(of: "type deviceCapture struct {") else {
            throw XCTSkip("device_capture_test.go no longer declares `deviceCapture`: update this reader")
        }
        let body = source[start.upperBound...]
        guard let innerStart = body.range(of: "struct {"), let innerEnd = body[innerStart.upperBound...].range(of: "}") else {
            throw XCTSkip("`deviceCapture` lost its inner assertion struct: update this reader")
        }
        func tags(_ text: Substring) -> [String] {
            text.components(separatedBy: "`json:\"").dropFirst().compactMap { piece in
                guard let end = piece.firstIndex(of: "\""), piece[piece.index(after: end)...].hasPrefix("`") else { return nil }
                return String(piece[..<end])
            }
        }
        let innerBody = body[innerStart.upperBound..<innerEnd.lowerBound]
        // Outer tags: everything before the inner struct, plus the tag that closes it, minus the inner ones.
        let outerBody = body[..<innerStart.lowerBound]
        let closing = body[innerEnd.upperBound...].prefix(while: { $0 != "\n" })
        let outerEnd = tags(outerBody) + tags(closing)
        return (Set(outerEnd), Set(tags(innerBody)))
    }

    // MARK: nothing sent, nothing kept, nothing before consent

    func testWithoutConsentApplesCallsAreNeverMade() async {
        let provider = Provider()
        do {
            _ = try await runner(provider, consent: false).capture()
            XCTFail("a capture without the agreement must throw")
        } catch {
            XCTAssertEqual(error as? AppAttestFailure, .needsConsent)
        }
        XCTAssertEqual(provider.made, [])
    }

    func testConsentIsReadAtTheTapNotWhenTheRunnerWasMade() async throws {
        let provider = Provider()
        final class Flag: @unchecked Sendable { var on = false }
        let flag = Flag()
        let late = AppAttestDeviceCaptureRunner(provider: provider, consent: { flag.on }, appID: appID, environment: "development")
        do { _ = try await late.capture(); XCTFail("no agreement yet") } catch { XCTAssertEqual(provider.made, []) }
        flag.on = true
        _ = try await late.capture()
        XCTAssertEqual(provider.made.first, "generateKey")
    }

    func testAnUnsupportedPhoneMakesNoKey() async {
        let provider = Provider(supported: false)
        do { _ = try await runner(provider).capture(); XCTFail("unsupported") } catch {
            XCTAssertEqual(error as? AppAttestFailure, .unsupported)
        }
        XCTAssertEqual(provider.made, [])
    }

    func testABuildThatCannotSayWhatItIsMakesNoKey() async {
        let table: [(appID: String, environment: String, field: String)] = [
            (".com.spokenmargins.native", "development", "appId"),  // no signing team in the build
            ("", "development", "appId"),
            ("J8SWC6J3VY.", "development", "appId"),
            ("J8SWC6J3VY", "development", "appId"),
            ("j8swc6j3vy.com.spokenmargins.native", "development", "appId"),
            ("J8SWC6J3VY.native", "development", "appId"),  // a bundle id has a reverse-domain shape
            ("$(DEVELOPMENT_TEAM).com.spokenmargins.native", "development", "appId"),  // an unexpanded build variable
            ("J8SWC6J3VY.com.spokenmargins.native", "", "environment"),
            ("J8SWC6J3VY.com.spokenmargins.native", "Development", "environment"),
            ("J8SWC6J3VY.com.spokenmargins.native", "$(SM_APP_ATTEST_ENVIRONMENT)", "environment"),
        ]
        for row in table {
            let provider = Provider()
            do {
                _ = try await runner(provider, appID: row.appID, environment: row.environment).capture()
                XCTFail("\(row) must be refused")
            } catch {
                XCTAssertEqual(error as? AppAttestCaptureFailure, .buildDescriptionMissing(row.field), "\(row)")
            }
            XCTAssertEqual(provider.made, [], "\(row)")
        }
    }

    func testEachFailureHasWordsTheOwnerCanActOn() {
        let table: [(Error, String)] = [
            (AppAttestFailure.needsConsent, "Agree to the sender check first"),
            (AppAttestFailure.unsupported, "can't use App Attest"),
            (AppAttestCaptureFailure.buildDescriptionMissing("appId"), "doesn't know its appId"),
            (AppAttestFailure.keyUnusable, "not usable"),
            (URLError(.cancelled), "switched on for the App ID"),
        ]
        for (error, expected) in table {
            XCTAssertTrue(AppAttestDeviceCaptureRunner.failureMessage(for: error).contains(expected), "\(error)")
        }
    }

    func testProductionIsAcceptedToo() async throws {
        let capture = try await runner(Provider(), environment: "production").capture()
        XCTAssertEqual(capture.environment, "production")
    }

    func testAnAppleFailureKeepsNothingAndLeavesTheSavedKeyAlone() async throws {
        let suite = "AppAttestDeviceCaptureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppAttestKeyStore(defaults: defaults)
        store.save("the-sender-checks-key")

        let provider = Provider()
        provider.failAttest = true
        do { _ = try await runner(provider).capture(); XCTFail("attest failed") } catch {}
        XCTAssertEqual(provider.made, ["generateKey", "attestKey"])

        _ = try await runner(Provider()).capture()
        // The runner never takes the store, so the sender check's key is exactly as it was, and no key id was kept.
        XCTAssertEqual(store.keyID, "the-sender-checks-key")
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.localizedCaseInsensitiveContains("attest") },
                       [AppAttestKeyStore.defaultsKey])
    }

    func testTheRunnerHasNoWayToSendAnything() throws {
        // The runner's only collaborators are Apple's provider, a consent closure, strings, a clock and a random source.
        // This reads its source so a transport, an address on our host or a key store can't be added without this
        // test failing and someone saying why.
        let source = try String(
            contentsOf: TestInputs.packageRoot.appending(path: "Sources/SessionKit/AppAttestDeviceCapture.swift"),
            encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for word in ["AttestedPost", "ProductServer", "URLSession", "AppAttestKeyStore", "UserDefaults", "Keychain", "SecItem"] {
            XCTAssertFalse(code.contains(word), "AppAttestDeviceCapture.swift mentions \(word): it must send and keep nothing")
        }
    }

    func testTheJSONIsPrettyAndStable() async throws {
        let capture = try await runner(Provider()).capture()
        let first = try capture.jsonData()
        XCTAssertEqual(first, try capture.jsonData())
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\n"))
        XCTAssertFalse(text.contains("\\/"), "base64 slashes must not be escaped")
        let decoded = try JSONDecoder().decode(AppAttestDeviceCapture.self, from: first)
        XCTAssertEqual(decoded, capture)
        XCTAssertEqual(AppAttestDeviceCapture.fileName, "device-capture.json")
    }
}
