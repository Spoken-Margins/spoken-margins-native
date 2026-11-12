import Foundation
import XCTest
@testable import SessionKit

/// The sender check before a link (#2239 step 3): what the server's answer means to the app, and that the permit
/// reaches the upload. Answers are copied from `research/B4/server/internal/api/sender.go`.
final class ShareLinkSenderCheckTests: XCTestCase {
    func testAnAllowedSenderGetsAPermit() throws {
        let body = Data(#"{"sharingAllowed":true,"sharingEnded":false,"permit":"abc123","permitExpiresAt":"2026-11-12T10:10:00.123456789Z"}"#.utf8)
        let standing = try XCTUnwrap(ShareLinkSenderCheck.decode(body))
        XCTAssertEqual(standing.permit, "abc123")
        XCTAssertTrue(standing.sharingAllowed)
        XCTAssertFalse(standing.sharingEnded)
        XCTAssertFalse(standing.hasTakedownNotice)
        XCTAssertNil(standing.sharingPausedUntil)
    }

    func testAPausedSenderGetsNoPermitAndTheDate() throws {
        let body = Data(#"{"sharingAllowed":false,"sharingEnded":false,"notice":"A link you shared was taken down after a report","sharingPausedUntil":"2026-11-19T10:00:00.5Z"}"#.utf8)
        let standing = try XCTUnwrap(ShareLinkSenderCheck.decode(body))
        XCTAssertNil(standing.permit)
        XCTAssertFalse(standing.sharingAllowed)
        XCTAssertTrue(standing.hasTakedownNotice)
        XCTAssertEqual(standing.sharingPausedUntil, Date(timeIntervalSince1970: 1_795_082_400.5))
    }

    func testAnEndedSenderIsEnded() throws {
        let body = Data(#"{"sharingAllowed":false,"sharingEnded":true}"#.utf8)
        XCTAssertEqual(try XCTUnwrap(ShareLinkSenderCheck.decode(body)).sharingEnded, true)
    }

    /// The server's dates, with and without a fraction and at any precision.
    func testTheServersDatesAllParse() {
        let whole = Date(timeIntervalSince1970: 1_795_082_400)
        for text in ["2026-11-19T10:00:00Z", "2026-11-19T10:00:00.000Z", "2026-11-19T10:00:00.000000000Z", "2026-11-19T10:00:00+00:00"] {
            XCTAssertEqual(ShareLinkSenderCheck.parseDate(text), whole, text)
        }
        for text in ["", "tomorrow", "2026-11-19", "2026-11-19T10:00:00.Z"] {
            XCTAssertNil(ShareLinkSenderCheck.parseDate(text), text)
        }
    }

    /// Neighbouring answers that are not an answer: each is a failure, never a permit.
    func testAnswersTheAppDoesNotUnderstandAreNotPermits() {
        let bad = [
            #"{"sharingAllowed":true,"sharingEnded":false}"#,
            #"{"sharingAllowed":true,"sharingEnded":false,"permit":""}"#,
            #"{"sharingAllowed":false,"sharingEnded":false,"permit":"abc"}"#,
            #"{"sharingAllowed":"yes","sharingEnded":false}"#,
            #"{}"#, "", "not json", #"[]"#
        ]
        for text in bad {
            XCTAssertNil(ShareLinkSenderCheck.decode(Data(text.utf8)), text)
        }
    }

    func testTheNoticeNamesNoCategory() {
        let text = ShareLinkTakedownNotice.text.lowercased()
        XCTAssertEqual(ShareLinkTakedownNotice.text, "A link you shared was taken down after a report")
        for word in ["abuse", "copyright", "harass", "hate", "intimate", "csam", "child", "defam"] {
            XCTAssertFalse(text.contains(word))
        }
    }

    func testThePendingNoticeSurvivesUntilCleared() {
        let name = "ShareLinkSenderCheckTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ShareLinkTakedownNoticeStore(defaults: defaults)
        XCTAssertFalse(store.isPending)
        store.setPending()
        XCTAssertTrue(ShareLinkTakedownNoticeStore(defaults: defaults).isPending, "a relaunch keeps it")
        store.clear()
        XCTAssertFalse(store.isPending)
    }

    func testThePauseAndEndMessagesAreGenericAndOfferTheFile() {
        for fallback in [ShareLinkFallback.sharingPaused, .sharingEnded] {
            let line = fallback.message
            XCTAssertTrue(line.contains("as a file"), line)
            XCTAssertFalse(line.lowercased().contains("report"), "the sender is never told why: \(line)")
        }
    }
}

/// `ShareLinkClient` with a sender check: it runs after consent and the server switch, before anything is sealed,
/// and its permit rides the upload.
final class ShareLinkSenderCheckClientTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String: String]] = []
        private var notices = 0
        var uploads: [[String: String]] { lock.withLock { stored } }
        var noticeCount: Int { lock.withLock { notices } }
        func upload(_ headers: [String: String]) { lock.withLock { stored.append(headers) } }
        func notice() { lock.withLock { notices += 1 } }
    }

    private let created = #"{"id":"0123456789abcdef0123456789abcdef","path":"/l/0123456789abcdef0123456789abcdef","expiresAt":"2026-12-03T00:00:00Z"}"#

    private func run(
        consent: Bool = true, state: ServerFeatureState = .on, check: ShareLinkSenderCheckOutcome?, recorder: Recorder
    ) async throws -> ShareLinkResult {
        let created = self.created
        let client = ShareLinkClient(
            server: { URL(string: "https://links.example.test\($0)")! },
            consent: { consent },
            senderCheck: check.map { outcome in { @Sendable in outcome } },
            takedownNotice: { recorder.notice() },
            post: { _, _, headers, _ in
                recorder.upload(headers)
                return (201, Data(created.utf8))
            }
        )
        let preview = try ShareLinkPreviewBuilder.make(title: "T", show: nil, pageURL: nil, enclosureURL: nil, marginTexts: ["Hello."])
        return await client.makeLink(packet: Data([1, 2, 3]), preview: preview, linksState: state)
    }

    private func standing(permit: String? = nil, until: Date? = nil, ended: Bool = false, notice: Bool = false) -> ShareLinkSenderCheckOutcome {
        .standing(ShareLinkSenderStanding(permit: permit, sharingPausedUntil: until, sharingEnded: ended, hasTakedownNotice: notice))
    }

    func testThePermitRidesTheUpload() async throws {
        let recorder = Recorder()
        let result = try await run(check: standing(permit: "p-1"), recorder: recorder)
        guard case .link = result else { return XCTFail("\(result)") }
        XCTAssertEqual(recorder.uploads, [["X-SM-Link-Permit": "p-1"]])
    }

    /// The server's refusals of a permit (links.go): told apart, not all "links aren't available".
    func testThePermitRefusalsAreToldApart() async throws {
        let preview = try ShareLinkPreviewBuilder.make(title: "T", show: nil, pageURL: nil, enclosureURL: nil, marginTexts: ["Hello."])
        let cases: [(String, ShareLinkFallback)] = [
            ("sharing_paused", .sharingPaused), ("bad_permit", .busy), ("permit_required", .busy), ("other", .failed)
        ]
        for (code, expected) in cases {
            let client = ShareLinkClient(
                consent: { true },
                senderCheck: { @Sendable in .standing(ShareLinkSenderStanding(permit: "p", sharingPausedUntil: nil, sharingEnded: false, hasTakedownNotice: false)) },
                post: { _, _, _, _ in (403, Data(#"{"error":"\#(code)"}"#.utf8)) }
            )
            let result = await client.makeLink(packet: Data([1]), preview: preview, linksState: .on)
            XCTAssertEqual(result, .useFile(expected), code)
        }
    }

    func testWithNoSenderCheckTheUploadCarriesNoIdentity() async throws {
        let recorder = Recorder()
        let result = try await run(check: nil, recorder: recorder)
        guard case .link = result else { return XCTFail("\(result)") }
        XCTAssertEqual(recorder.uploads, [[:]])
    }

    func testAPhoneThatCannotAttestStillMakesTheLinkWithoutAPermit() async throws {
        let recorder = Recorder()
        let result = try await run(check: .notChecked, recorder: recorder)
        guard case .link = result else { return XCTFail("\(result)") }
        XCTAssertEqual(recorder.uploads, [[:]])
    }

    func testAPausedSenderMakesNoLinkAndNothingIsUploaded() async throws {
        let recorder = Recorder()
        let result = try await run(check: standing(until: Date(timeIntervalSince1970: 1_795_082_400)), recorder: recorder)
        XCTAssertEqual(result, .useFile(.sharingPaused))
        XCTAssertEqual(recorder.uploads.count, 0)
    }

    func testAnEndedSenderMakesNoLink() async throws {
        let recorder = Recorder()
        let result = try await run(check: standing(ended: true), recorder: recorder)
        XCTAssertEqual(result, .useFile(.sharingEnded))
        XCTAssertEqual(recorder.uploads.count, 0)
    }

    func testAFailedCheckMakesNoLink() async throws {
        let recorder = Recorder()
        for fallback in [ShareLinkFallback.offline, .unavailable, .busy, .failed] {
            let result = try await run(check: .failed(fallback), recorder: recorder)
            XCTAssertEqual(result, .useFile(fallback))
        }
        XCTAssertEqual(recorder.uploads.count, 0)
    }

    func testTheTakedownNoticeIsPassedOnEvenWhenSharingIsPaused() async throws {
        let recorder = Recorder()
        _ = try await run(check: standing(until: Date(), notice: true), recorder: recorder)
        XCTAssertEqual(recorder.noticeCount, 1)
        _ = try await run(check: standing(permit: "p", notice: true), recorder: recorder)
        XCTAssertEqual(recorder.noticeCount, 2)
        _ = try await run(check: standing(permit: "p"), recorder: recorder)
        XCTAssertEqual(recorder.noticeCount, 2, "no notice from the server, none shown")
    }

    func testTheCheckNeverRunsBeforeConsentOrWhenTheServerSwitchIsOff() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            var value: Int { lock.withLock { n } }
            func bump() { lock.withLock { n += 1 } }
        }
        let counter = Counter()
        let check: @Sendable () async -> ShareLinkSenderCheckOutcome = { counter.bump(); return .notChecked }
        let preview = try ShareLinkPreviewBuilder.make(title: "T", show: nil, pageURL: nil, enclosureURL: nil, marginTexts: ["Hello."])
        let noConsent = ShareLinkClient(consent: { false }, senderCheck: check, post: { _, _, _, _ in (201, Data()) })
        let first = await noConsent.makeLink(packet: Data([1]), preview: preview, linksState: .on)
        XCTAssertEqual(first, .needsConsent)
        let switchedOff = ShareLinkClient(consent: { true }, senderCheck: check, post: { _, _, _, _ in (201, Data()) })
        let second = await switchedOff.makeLink(packet: Data([1]), preview: preview, linksState: .off(.switchedOff))
        XCTAssertEqual(second, .useFile(.unavailable))
        XCTAssertEqual(counter.value, 0)
    }
}

/// `ShareLinkSenderCheck.check` over a real `AttestedServerClient`: every way the attested request can end.
final class ShareLinkSenderCheckLiveTests: XCTestCase {
    private final class Provider: AppAttestKeyProvider, @unchecked Sendable {
        let supported: Bool
        let fails: Bool
        init(supported: Bool = true, fails: Bool = false) { self.supported = supported; self.fails = fails }
        var isSupported: Bool { supported }
        func generateKey() async throws -> String {
            if fails { throw URLError(.cancelled) }
            return Data(repeating: 7, count: 32).base64EncodedString()
        }
        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { Data("a".utf8) }
        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { Data("s".utf8) }
    }

    private func outcome(
        supported: Bool = true, consent: Bool = true, offline: Bool = false, status: Int = 200, registerStatus: Int = 201,
        appleFails: Bool = false, body: String
    ) async -> ShareLinkSenderCheckOutcome {
        let name = "ShareLinkSenderCheckLiveTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let client = AttestedServerClient(
            provider: Provider(supported: supported, fails: appleFails), store: AppAttestKeyStore(defaults: defaults), consent: { consent },
            server: { URL(string: "https://links.example.test\($0)")! }
        ) { url, _, _ in
            if offline { throw URLError(.notConnectedToInternet) }
            switch url.path {
            case "/api/v1/attest/challenge": return (200, Data(#"{"challenge":"\#(Data(repeating: 1, count: 32).base64EncodedString())"}"#.utf8))
            case "/api/v1/attest/register": return (registerStatus, Data("{}".utf8))
            default: return (status, Data(body.utf8))
            }
        }
        return await ShareLinkSenderCheck.check(using: client)
    }

    func testAnAllowedAnswerIsAStandingWithAPermit() async {
        let result = await outcome(body: #"{"sharingAllowed":true,"sharingEnded":false,"permit":"p"}"#)
        XCTAssertEqual(result, .standing(ShareLinkSenderStanding(permit: "p", sharingPausedUntil: nil, sharingEnded: false, hasTakedownNotice: false)))
    }

    func testASimulatorIsNotChecked() async {
        let result = await outcome(supported: false, body: "")
        XCTAssertEqual(result, .notChecked)
    }

    /// A fault in attesting must not take links from every sender while the server asks for no permit: Apple's call
    /// failing (no entitlement yet), the server not accepting the registration, or an answer the app has no line for
    /// all mean "standing unknown", and the link goes ahead without a permit.
    func testAFaultInAttestingLeavesTheLinkOnWithoutAPermit() async {
        let apple = await outcome(appleFails: true, body: "")
        XCTAssertEqual(apple, .notChecked)
        let registration = await outcome(registerStatus: 401, body: "")
        XCTAssertEqual(registration, .notChecked)
        for status in [400, 401, 404, 500, 502] {
            let other = await outcome(status: status, body: #"{"error":"x"}"#)
            XCTAssertEqual(other, .notChecked, "\(status)")
        }
    }

    func testEveryOtherEndingIsAFailureTheScreenAlreadySays() async {
        let offline = await outcome(offline: true, body: "")
        XCTAssertEqual(offline, .failed(.offline))
        let blocked = await outcome(status: 403, body: #"{"error":"refused"}"#)
        XCTAssertEqual(blocked, .failed(.unavailable))
        let limited = await outcome(status: 429, body: #"{"error":"rate_limited"}"#)
        XCTAssertEqual(limited, .failed(.busy))
        let off = await outcome(status: 503, body: #"{"error":"disabled"}"#)
        XCTAssertEqual(off, .failed(.unavailable))
        let garbled = await outcome(body: "nonsense")
        XCTAssertEqual(garbled, .failed(.failed))
        let noConsent = await outcome(consent: false, body: "")
        XCTAssertEqual(noConsent, .failed(.unavailable))
    }
}
