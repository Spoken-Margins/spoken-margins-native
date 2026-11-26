import Foundation
import XCTest
@testable import SessionKit

/// The reply box's words (banner C, card D, sheet E), its close, report and report-reason requests, the new file-button
/// caption and the consent copy (#4675, `docs/design/reply-mailbox.md` piece 5 and screen A).
final class ReplyBoxWordsAndRequestsTests: XCTestCase {
    private func arrival(_ sender: String?, item: String = "item-1", title: String = "The Harbour", seq: Int = 1, new: Int = 1) -> ReplyArrival {
        ReplyArrival(boxId: "box", seq: seq, layerId: "layer-\(seq)", itemId: item, itemTitle: title, senderLabel: sender, newMarginCount: new)
    }

    // MARK: C. Banner

    func testBannerBranches() {
        XCTAssertNil(ReplyArrivalWords.banner(for: []))
        XCTAssertNil(ReplyArrivalWords.banner(for: [arrival("Dana", new: 0)]), "a packet already in is not news")

        let one = ReplyArrivalWords.banner(for: [arrival("Dana"), arrival(" Dana ", seq: 2)])
        XCTAssertEqual(one?.text, "Dana answered you on The Harbour")
        XCTAssertEqual(one?.openTitle, "Open")
        XCTAssertEqual(one?.destination, .item(id: "item-1"))

        XCTAssertEqual(ReplyArrivalWords.banner(for: [arrival(nil)])?.text, "A friend answered you on The Harbour")
        XCTAssertEqual(ReplyArrivalWords.banner(for: [arrival("  ")])?.text, "A friend answered you on The Harbour")
        XCTAssertEqual(ReplyArrivalWords.banner(for: [arrival("Your friend")])?.text, "A friend answered you on The Harbour",
                       "a stand-in label is no name")
        XCTAssertEqual(ReplyArrivalWords.banner(for: [arrival("Dana", title: "  ")])?.text, "Dana answered you")

        let friends = ReplyArrivalWords.banner(for: [arrival("Dana"), arrival("Ari", seq: 2), arrival(nil, seq: 3)])
        XCTAssertEqual(friends?.text, "New answers from 3 friends")
        XCTAssertEqual(friends?.destination, .following)
        XCTAssertEqual(ReplyArrivalWords.banner(for: [arrival(nil), arrival(nil, seq: 2)])?.text, "A friend answered you on The Harbour",
                       "unnamed answers count as one friend, as Following groups them")
        XCTAssertEqual(ReplyArrivalWords.banner(for: [arrival("Dana"), arrival("DANA", seq: 2)])?.text, "Dana answered you on The Harbour",
                       "the same name in another case is the same friend")

        let items = ReplyArrivalWords.banner(for: [arrival("Dana"), arrival("Dana", item: "item-2", title: "Other", seq: 2), arrival("Dana", seq: 3)])
        XCTAssertEqual(items?.text, "3 new answers from Dana")
        XCTAssertEqual(items?.destination, .following)
    }

    // MARK: D and E

    func testCardAndSheetWords() {
        XCTAssertEqual(ReplyArrivalWords.stopConfirmMessage(senderLabel: "Dana"), "Dana can still listen. New answers through this link won't reach you.")
        XCTAssertEqual(ReplyArrivalWords.stopConfirmMessage(senderLabel: nil), "A friend can still listen. New answers through this link won't reach you.")
        XCTAssertEqual(ReplyArrivalWords.stopConfirmTitle, "Stop answers through this link?")
        XCTAssertEqual(ReplyArrivalWords.stopConfirmButton, "Stop Answers")
        XCTAssertEqual(ReplyArrivalWords.stopDone, "Answers through this link are stopped.")
        XCTAssertEqual(ReplyArrivalWords.stoppedRow, "Answers through this link are stopped")
        XCTAssertEqual(ReplyArrivalWords.stopFailed, "Couldn't stop answers. Check your connection and try again.")
        XCTAssertEqual(ReplyArrivalWords.namesAreTyped, "Names on answers are typed by whoever sends them.")
        XCTAssertEqual(ReplyArrivalWords.reportTitle, "Report this answer")
        XCTAssertEqual(ReplyArrivalWords.reportSent(reference: "R-12", closeFailed: false), "Report sent. Reference R-12.")
        XCTAssertEqual(ReplyArrivalWords.reportSent(reference: "R-12", closeFailed: true),
                       "Report sent. Reference R-12. Couldn't stop answers. Try again from the card.")
        XCTAssertEqual(ReplyArrivalWords.reportSent(reference: nil, closeFailed: false), "Report sent.")
        XCTAssertEqual(ReplyArrivalWords.reportBoxEnded, "Hidden on this phone. The link has ended, so nothing of it is left on our server.")
        XCTAssertEqual(ReplyReportCategory.allCases.map(\.rawValue),
                       ["intimate_images", "abuse_material", "harassment", "hateful_conduct", "copyright", "other"])
        XCTAssertEqual(ReplyReportCategory.allCases.map(\.title), [
            "Intimate content shared without consent", "Child sexual abuse material", "Harassment or defamation",
            "Hateful conduct", "Copyright", "Other",
        ])
        XCTAssertEqual(ReplyReportCategory.allCases.filter(\.sendsFullLink), [.abuseMaterial])
    }

    // MARK: Requests

    private func record(_ box: ReplyBox) -> ReplyBoxRecord {
        ReplyBoxRecord(box: box, linkId: String(repeating: "a", count: 32), itemId: "i", sharedPackageDigest: "d",
                       createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 1))
    }

    private func fields(_ request: ClubClient.Request) -> [String: String] {
        var result: [String: String] = [:]
        for pair in String(decoding: request.body ?? Data(), as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            result[parts[0].removingPercentEncoding!] = (parts.count > 1 ? parts[1] : "").removingPercentEncoding!
        }
        return result
    }

    func testCloseCarriesTheReadProofAndNothingElse() throws {
        let box = ReplyBox.random()
        let request = try ReplyBoxRequests.close(record(box))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/clubs/\(box.id)/close")
        XCTAssertEqual(request.bearer, box.credentials.readProof)
        XCTAssertNil(request.body)
        for status in [200, 404, 410] { XCTAssertEqual(ReplyBoxRequests.closeOutcome(status: status), .closed, "\(status)") }
        for status in [429, 500, 503, 400] { XCTAssertEqual(ReplyBoxRequests.closeOutcome(status: status), .failed, "\(status)") }
    }

    func testAReportNamesTheCategoryAndPostAndOnlyAbuseMaterialCarriesTheLink() throws {
        let box = ReplyBox.random()
        let request = try ReplyBoxRequests.report(record(box), seq: 3, category: .harassment, reason: "  Rude & mean = bad + #1 ", host: "spokenmargins.com")
        XCTAssertEqual(request.path, "/api/v1/clubs/\(box.id)/report")
        XCTAssertEqual(request.bearer, box.credentials.readProof)
        XCTAssertEqual(request.contentType, "application/x-www-form-urlencoded")
        XCTAssertEqual(fields(request), ["category": "harassment", "post": "3", "reason": "Rude & mean = bad + #1"])
        XCTAssertFalse(String(decoding: request.body!, as: UTF8.self).contains(box.key.fragment), "K stays home")

        let noReason = try ReplyBoxRequests.report(record(box), seq: 1, category: .other, reason: "   ", host: "spokenmargins.com")
        XCTAssertEqual(fields(noReason), ["category": "other", "post": "1"])

        let abuse = try ReplyBoxRequests.report(record(box), seq: 2, category: .abuseMaterial, reason: nil, host: "spokenmargins.com")
        XCTAssertEqual(fields(abuse), [
            "category": "abuse_material", "post": "2", "link": "https://spokenmargins.com/c/\(box.id)#\(box.key.fragment)",
        ])
        XCTAssertThrowsError(try ReplyBoxRequests.report(record(box), seq: 0, category: .other, reason: nil, host: "spokenmargins.com"))
    }

    func testTheReasonRouteAndADamagedRecord() throws {
        let box = ReplyBox.random()
        let request = try ReplyBoxRequests.reportReason(record(box), reference: "R-12", reason: " It was spam. ")
        XCTAssertEqual(request.path, "/api/v1/clubs/\(box.id)/report/reason")
        XCTAssertEqual(request.bearer, box.credentials.readProof)
        XCTAssertEqual(fields(request), ["ref": "R-12", "reason": "It was spam."])
        var damaged = record(box)
        damaged.key = ReplyBox.Key.random().fragment
        XCTAssertThrowsError(try ReplyBoxRequests.close(damaged)) { XCTAssertEqual($0 as? ReplyBoxRequests.Failure, .damagedRecord) }
    }

    func testReportAnswers() {
        XCTAssertEqual(ReplyBoxRequests.reportOutcome(status: 200, body: Data(#"{"filed":true,"reasonOutstanding":false,"ref":"R-1"}"#.utf8)),
                       .sent(reference: "R-1", reasonOutstanding: false))
        XCTAssertEqual(ReplyBoxRequests.reportOutcome(status: 200, body: Data(#"{"filed":true,"reasonOutstanding":true,"ref":"R-2"}"#.utf8)),
                       .sent(reference: "R-2", reasonOutstanding: true))
        XCTAssertEqual(ReplyBoxRequests.reportOutcome(status: 200, body: Data("nope".utf8)), .failed)
        XCTAssertEqual(ReplyBoxRequests.reportOutcome(status: 404, body: Data()), .boxEnded)
        XCTAssertEqual(ReplyBoxRequests.reportOutcome(status: 429, body: Data()), .failed)
        XCTAssertTrue(ReplyBoxRequests.reportReasonSucceeded(status: 200))
        XCTAssertFalse(ReplyBoxRequests.reportReasonSucceeded(status: 400))
    }

    // MARK: Screen A

    func testTheCaptionByFlag() {
        XCTAssertEqual(ShareFileMessage.caption(linksOffered: true, repliesOffered: true),
                       "A link opens in any browser, and your friend can answer through it. Your friend needs Spoken Margins to open a file.")
        XCTAssertEqual(ShareFileMessage.caption(linksOffered: true, repliesOffered: false),
                       "Your friend needs Spoken Margins to open a file. A link opens in any browser.")
        XCTAssertEqual(ShareFileMessage.caption(linksOffered: true, repliesOffered: false), ShareFileMessage.caption(linksOffered: true))
        XCTAssertEqual(ShareFileMessage.caption(linksOffered: false, repliesOffered: true), "Your friend needs Spoken Margins to open a file.")
        XCTAssertEqual(ShareFileMessage.caption(linksOffered: false, repliesOffered: false), ShareFileMessage.caption(linksOffered: false))
    }

    func testTheConsentWordsAndVersionByFlag() throws {
        XCTAssertEqual(ShareLinkConsentCopy.message(repliesOffered: false), ShareLinkConsentCopy.message)
        let withAnswers = ShareLinkConsentCopy.message(repliesOffered: true)
        let paragraphs = withAnswers.components(separatedBy: "\n\n")
        XCTAssertEqual(paragraphs.count, ShareLinkConsentCopy.message.components(separatedBy: "\n\n").count + 1)
        XCTAssertEqual(paragraphs[1], "Your friend can answer through the link. Their answers are locked the same way, wait on our server until your phone collects them or the link ends, and only your phone can open them.")
        XCTAssertTrue(paragraphs[0].hasPrefix("A link puts your Margins on our server"))
        XCTAssertEqual(ServerSendConsent.disclosureVersion(repliesOffered: false), 2)
        XCTAssertEqual(ServerSendConsent.disclosureVersion(repliesOffered: true), 3)

        let name = "ReplyBoxConsent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        ServerSendConsent.record(.shareLinks, in: defaults)
        XCTAssertTrue(ServerSendConsent.hasConsented(to: .shareLinks, in: defaults))
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .shareLinks, repliesOffered: true, in: defaults),
                       "who agreed to version 2 is asked once more when links carry answers")
        ServerSendConsent.record(.shareLinks, repliesOffered: true, in: defaults)
        XCTAssertTrue(ServerSendConsent.hasConsented(to: .shareLinks, repliesOffered: true, in: defaults))
    }
}
