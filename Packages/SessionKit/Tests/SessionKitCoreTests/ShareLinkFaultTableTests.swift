import Foundation
import XCTest
@testable import SessionKit

/// The #4134 Design's fault table: every way the sender check or the upload can fail, against the owner's call of
/// 2026-11-12. With refuse mode off (today, until the App Attest entitlement ships and a real phone is accepted, #1593) a
/// faulted check still makes the link, unattributed. With it on, each fault stops with its own line, and a refusal that
/// won't pass on a retry never says "try again in a little while".
final class ShareLinkFaultTableTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var uploads: [[String: String]] = []
        private var checks = 0
        var uploaded: [[String: String]] { lock.withLock { uploads } }
        var checkCount: Int { lock.withLock { checks } }
        func upload(_ headers: [String: String]) -> Int { lock.withLock { uploads.append(headers); return uploads.count } }
        func check() -> Int { lock.withLock { checks += 1; return checks } }
    }

    private static let created = #"{"id":"0123456789abcdef0123456789abcdef","path":"/l/0123456789abcdef0123456789abcdef","expiresAt":"2026-12-03T00:00:00Z"}"#

    private func preview() throws -> ShareLinkPreview {
        try ShareLinkPreviewBuilder.make(title: "T", show: nil, pageURL: nil, enclosureURL: nil, marginTexts: ["Hello."])
    }

    /// Runs one link with the sender check giving `checks` in turn (the last repeats) and the upload answering `uploads`
    /// in turn (the last repeats).
    private func run(
        policy: ShareLinkFaultPolicy,
        checks: [ShareLinkSenderCheckOutcome],
        uploads: [(Int, String)] = [(201, created)],
        linksState: ServerFeatureState = .on,
        recorder: Recorder = Recorder()
    ) async throws -> ShareLinkResult {
        let client = ShareLinkClient(
            server: { URL(string: "https://links.example.test\($0)")! },
            consent: { true },
            senderCheck: { @Sendable in
                let n = recorder.check()
                return checks[min(n, checks.count) - 1]
            },
            post: { _, _, headers, _ in
                let n = recorder.upload(headers)
                let answer = uploads[min(n, uploads.count) - 1]
                return (answer.0, Data(answer.1.utf8))
            }
        )
        return await client.makeLink(packet: Data([1, 2, 3]), preview: try preview(), linksState: linksState, faultPolicy: policy)
    }

    // MARK: The sender check's faults, one row per line of the table, in both modes

    /// (reason, line in refuse mode, or nil for "link, no permit").
    private let table: [(ShareLinkUncheckedReason, ShareLinkFallback?)] = [
        (.cannotAttest, .phoneCantMakeLinks),
        (.attestFailed, .notVerified),
        (.registrationWaiting, .cantVerify),
        (.clockSkew, .clockWrong),
        (.unknownKey, .cantVerify),
        (.invalidAssertionOnce, .notVerified),
        (.invalidAssertion, .cantVerify),
        (.missingAssertion, .cantVerify),
        (.rejected, .cantVerify),
        // The server operator's switch keeps its meaning in both modes: links still work, unattributed.
        (.operatorDisabled, nil),
        (.serverError, .unavailable),
    ]

    func testTheTableCoversEveryReason() {
        XCTAssertEqual(Set(table.map(\.0)), Set(ShareLinkUncheckedReason.allCases))
    }

    /// The owner's call, today: while the entitlement isn't shipped, no fault takes the link away.
    func testWithRefuseModeOffAFaultInAttestingLeavesTheLinkOnWithoutAPermit() async throws {
        for (reason, _) in table {
            let recorder = Recorder()
            let result = try await run(policy: .off, checks: [.notChecked(reason)], recorder: recorder)
            guard case .link = result else { XCTFail("\(reason): \(result)"); continue }
            XCTAssertEqual(recorder.uploaded, [[:]], "\(reason): uploaded with no permit")
        }
    }

    func testWithRefuseModeOnEachFaultStopsWithItsOwnLine() async throws {
        for (reason, line) in table {
            let recorder = Recorder()
            let result = try await run(policy: .refuse, checks: [.notChecked(reason)], recorder: recorder)
            if let line {
                XCTAssertEqual(result, .useFile(line), "\(reason)")
                XCTAssertEqual(recorder.uploaded.count, 0, "\(reason): nothing uploaded")
            } else {
                guard case .link = result else { XCTFail("\(reason): \(result)"); continue }
                XCTAssertEqual(recorder.uploaded, [[:]])
            }
        }
    }

    /// The build's switch: absent (today) is off; only the Boolean true turns it on.
    func testRefuseModeIsOffUnlessTheInfoPlistSaysTrue() {
        XCTAssertEqual(ShareLinkFaultPolicy.fromInfoPlist(nil), .off)
        XCTAssertEqual(ShareLinkFaultPolicy.fromInfoPlist([:]), .off)
        XCTAssertEqual(ShareLinkFaultPolicy.fromInfoPlist([ShareLinkFaultPolicy.infoPlistKey: false]), .off)
        XCTAssertEqual(ShareLinkFaultPolicy.fromInfoPlist([ShareLinkFaultPolicy.infoPlistKey: 1]), .off)
        XCTAssertEqual(ShareLinkFaultPolicy.fromInfoPlist([ShareLinkFaultPolicy.infoPlistKey: true]), .refuse)
        // A build setting reaches the plist as text: an unset one is empty, which is off.
        for text in ["", "$(SM_SHARE_LINK_REFUSE_UNCHECKED)", "NO", "no", "false", "0", "YESS"] {
            XCTAssertEqual(ShareLinkFaultPolicy.fromInfoPlist([ShareLinkFaultPolicy.infoPlistKey: text]), .off, text)
        }
        for text in ["YES", "yes", "true", "TRUE", " YES "] {
            XCTAssertEqual(ShareLinkFaultPolicy.fromInfoPlist([ShareLinkFaultPolicy.infoPlistKey: text]), .refuse, text)
        }
    }

    // MARK: The upload's refusals

    private let allowed = ShareLinkSenderCheckOutcome.standing(
        ShareLinkSenderStanding(permit: "p-1", sharingPausedUntil: nil, sharingEnded: false, hasTakedownNotice: false))
    private let allowedAgain = ShareLinkSenderCheckOutcome.standing(
        ShareLinkSenderStanding(permit: "p-2", sharingPausedUntil: nil, sharingEnded: false, hasTakedownNotice: false))

    /// Only once the server flag is on: a phone that sent no permit gets `permit_required`, which a retry won't fix.
    func testPermitRequiredIsFinalInBothModes() async throws {
        for policy in [ShareLinkFaultPolicy.off, .refuse] {
            let recorder = Recorder()
            let result = try await run(policy: policy, checks: [.notChecked(.operatorDisabled)], uploads: [(403, #"{"error":"permit_required"}"#)], recorder: recorder)
            XCTAssertEqual(result, .useFile(.cantVerify), "\(policy)")
            XCTAssertEqual(recorder.uploaded.count, 1, "no retry")
            XCTAssertFalse(ShareLinkFallback.cantVerify.message.lowercased().contains("try again"))
        }
    }

    /// A permit can expire between the check and the upload: one fresh check, one more upload with the new permit.
    func testABadPermitGetsOneFreshCheckAndOneMoreUpload() async throws {
        for policy in [ShareLinkFaultPolicy.off, .refuse] {
            let recorder = Recorder()
            let result = try await run(
                policy: policy, checks: [allowed, allowedAgain],
                uploads: [(403, #"{"error":"bad_permit"}"#), (201, Self.created)], recorder: recorder)
            guard case .link = result else { XCTFail("\(policy): \(result)"); continue }
            XCTAssertEqual(recorder.checkCount, 2)
            XCTAssertEqual(recorder.uploaded, [["X-SM-Link-Permit": "p-1"], ["X-SM-Link-Permit": "p-2"]])
        }
    }

    func testASecondBadPermitIsFinal() async throws {
        for policy in [ShareLinkFaultPolicy.off, .refuse] {
            let recorder = Recorder()
            let result = try await run(policy: policy, checks: [allowed, allowedAgain], uploads: [(403, #"{"error":"bad_permit"}"#)], recorder: recorder)
            XCTAssertEqual(result, .useFile(.cantVerify), "\(policy)")
            XCTAssertEqual(recorder.checkCount, 2)
            XCTAssertEqual(recorder.uploaded.count, 2, "one retry, not a loop")
        }
    }

    /// The fresh check is read like the first: paused in between stops the link, and a fault follows the mode.
    func testTheFreshCheckFollowsTheSameRules() async throws {
        let paused = ShareLinkSenderCheckOutcome.standing(
            ShareLinkSenderStanding(permit: nil, sharingPausedUntil: Date(), sharingEnded: false, hasTakedownNotice: false))
        let pausedResult = try await run(policy: .off, checks: [allowed, paused], uploads: [(403, #"{"error":"bad_permit"}"#)])
        XCTAssertEqual(pausedResult, .useFile(.sharingPaused))
        let refused = try await run(policy: .refuse, checks: [allowed, .notChecked(.clockSkew)], uploads: [(403, #"{"error":"bad_permit"}"#)])
        XCTAssertEqual(refused, .useFile(.clockWrong))
        let recorder = Recorder()
        let unattributed = try await run(
            policy: .off, checks: [allowed, .notChecked(.clockSkew)],
            uploads: [(403, #"{"error":"bad_permit"}"#), (201, Self.created)], recorder: recorder)
        guard case .link = unattributed else { return XCTFail("\(unattributed)") }
        XCTAssertEqual(recorder.uploaded, [["X-SM-Link-Permit": "p-1"], [:]])
    }

    /// The `links` service's `minimumBuild` above this build: say to update, in both modes, and ask nothing.
    func testABuildBelowTheMinimumIsToldToUpdate() async throws {
        for policy in [ShareLinkFaultPolicy.off, .refuse] {
            let recorder = Recorder()
            let result = try await run(policy: policy, checks: [allowed], linksState: .off(.buildTooOld(minimumBuild: 99)), recorder: recorder)
            XCTAssertEqual(result, .useFile(.updateNeeded))
            XCTAssertEqual(recorder.checkCount, 0)
            XCTAssertEqual(recorder.uploaded.count, 0)
        }
        let switchedOff = try await run(policy: .off, checks: [allowed], linksState: .off(.switchedOff))
        XCTAssertEqual(switchedOff, .useFile(.unavailable), "other off reasons are unchanged")
    }

    // MARK: The lines

    func testTheNewLinesSayWhatHappenedAndOfferTheFile() {
        let lines: [(ShareLinkFallback, String)] = [
            (.clockWrong, "Your iPhone's date and time look wrong, so a link can't be made. Turn on Set Automatically in Settings, General, Date & Time, then try again. You can still send them as a file."),
            (.notVerified, "This iPhone couldn't be checked for links just now. Try again in a few minutes, or send them as a file."),
            (.cantVerify, "Links can't be made from this iPhone right now. You can still send them as a file."),
            (.phoneCantMakeLinks, "This iPhone can't make links. You can still send them as a file."),
            (.updateNeeded, "Update Spoken Margins to share links. You can still send them as a file."),
        ]
        for (fallback, text) in lines {
            XCTAssertEqual(fallback.message, text)
            XCTAssertTrue(text.contains("as a file"))
        }
    }

    /// A refusal that won't pass on a retry doesn't offer one: the button follows the line.
    func testTheButtonFollowsTheLine() {
        let rules: [(ShareLinkFallback, ShareLinkButtonAfterFallback)] = [
            (.clockWrong, .enabled), (.notVerified, .enabled), (.cantVerify, .disabledUntilReopened),
            (.phoneCantMakeLinks, .disabled), (.updateNeeded, .hidden),
            (.busy, .enabled), (.unavailable, .enabled), (.offline, .enabled), (.failed, .enabled), (.tooLarge, .enabled),
            (.nothingToSay, .enabled), (.sharingPaused, .enabled), (.sharingEnded, .enabled),
        ]
        for (fallback, rule) in rules {
            XCTAssertEqual(fallback.shareLinkAfterwards, rule, "\(fallback)")
            XCTAssertEqual(rule.allowsShareLink, rule == .enabled)
            // Every Share button picks the link only when it may; otherwise it sends the file, never nothing.
            XCTAssertEqual(rule.makesLink(offered: true), rule == .enabled, "\(fallback)")
            XCTAssertFalse(rule.makesLink(offered: false), "\(fallback): links not offered")
            if !rule.allowsShareLink {
                XCTAssertFalse(fallback.message.lowercased().contains("try again"), "\(fallback) offers no retry it can't keep")
            }
        }
    }
}
