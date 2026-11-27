#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// The reply box's secrets, sealed part, upload headers and record (#4675, `docs/design/reply-mailbox.md` piece 3),
/// checked against the vector the Go server and the web listener also read.
final class ReplyBoxTests: XCTestCase {
    private struct Vector: Decodable {
        struct Sealed: Decodable {
            let aadHex: String
            let nonceHex: String
            let part: Int
            let plaintext: String?
            let plaintextBase64: String?
            let sealedBase64: String
        }
        let answer: Sealed
        let boxKeyFragment: String
        let id: String
        let linkKeyFragment: String
        let postHash: String
        let postProof: String
        let readHash: String
        let readProof: String
        let replyPart: Sealed
        let sealKeyBase64URL: String
        let sealKeyHex: String
        let uploadHeaders: [String: String]

        static func load() throws -> Vector {
            try JSONDecoder().decode(Vector.self, from: TestInputs.data(.research, "B4/contracts/fixtures/reply-box-vector.json"))
        }
    }

    // MARK: The shared vector

    func testTheBoxDerivesEveryValueOfTheVector() throws {
        let vector = try Vector.load()
        let box = ReplyBox(key: try XCTUnwrap(ReplyBox.Key(fragment: vector.boxKeyFragment)))
        XCTAssertEqual(box.id, vector.id)
        XCTAssertEqual(box.credentials.readProof, vector.readProof)
        XCTAssertEqual(box.credentials.postProof, vector.postProof)
        XCTAssertEqual(box.credentials.readHash, vector.readHash)
        XCTAssertEqual(box.credentials.postHash, vector.postHash)
        XCTAssertEqual(ClubSealing.Credentials.hex(box.credentials.sealKey), vector.sealKeyHex)
        XCTAssertEqual(box.sealKeyBase64URL, vector.sealKeyBase64URL)
        XCTAssertEqual(box.invite.id, vector.id, "the box lists and fetches as a club")
    }

    func testTheReplyPartSealsAndOpensByteForByte() throws {
        let vector = try Vector.load()
        let box = ReplyBox(key: try XCTUnwrap(ReplyBox.Key(fragment: vector.boxKeyFragment)))
        let linkKey = try XCTUnwrap(ShareLinkSealing.Key(fragment: vector.linkKeyFragment))
        XCTAssertEqual(vector.replyPart.part, Int(ShareLinkSealing.Part.reply.rawValue))
        XCTAssertEqual(String(decoding: try box.replyPartJSON(), as: UTF8.self), vector.replyPart.plaintext)
        let nonce = try AES.GCM.Nonce(data: try XCTUnwrap(Data(hexString: vector.replyPart.nonceHex)))
        let sealed = try box.sealedReplyPart(linkKey: linkKey, nonce: nonce)
        XCTAssertEqual(sealed.base64EncodedString(), vector.replyPart.sealedBase64)
        XCTAssertEqual(ClubSealing.Credentials.hex(sealed.prefix(8)), vector.replyPart.aadHex, "additional data = the 8-byte header only")
        XCTAssertLessThanOrEqual(sealed.count, ReplyBox.maximumSealedReplyPartBytes)
        let opened = try ReplyBox.openReplyPart(sealed, linkKey: linkKey)
        XCTAssertEqual(opened, ReplyBox.Part(v: 1, box: vector.id, post: vector.postProof, seal: vector.sealKeyBase64URL))
    }

    func testTheFourUploadHeadersAreTheVectorsAndNoSecretRidesThem() throws {
        let vector = try Vector.load()
        let box = ReplyBox(key: try XCTUnwrap(ReplyBox.Key(fragment: vector.boxKeyFragment)))
        let linkKey = try XCTUnwrap(ShareLinkSealing.Key(fragment: vector.linkKeyFragment))
        let nonce = try AES.GCM.Nonce(data: try XCTUnwrap(Data(hexString: vector.replyPart.nonceHex)))
        let headers = try box.uploadHeaders(linkKey: linkKey, nonce: nonce)
        XCTAssertEqual(headers, vector.uploadHeaders)
        let all = headers.values.joined(separator: " ")
        for secret in [box.key.fragment, box.credentials.readProof, box.credentials.postProof, box.sealKeyBase64URL] {
            XCTAssertFalse(all.contains(secret), "the server must not get \(secret.prefix(6))…")
        }
    }

    func testAnAnswerIsAClubPostThatOpensToTheExactPacket() throws {
        let vector = try Vector.load()
        let box = ReplyBox(key: try XCTUnwrap(ReplyBox.Key(fragment: vector.boxKeyFragment)))
        let plaintext = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector.answer.plaintextBase64)))
        let sealed = try XCTUnwrap(Data(base64Encoded: vector.answer.sealedBase64))
        XCTAssertEqual(vector.answer.part, 2)
        XCTAssertEqual(ClubSealing.Credentials.hex(ClubSealing.associatedData(for: .post, in: box.credentials)), vector.answer.aadHex)
        let nonce = try AES.GCM.Nonce(data: try XCTUnwrap(Data(hexString: vector.answer.nonceHex)))
        XCTAssertEqual(try box.sealAnswer(plaintext, nonce: nonce), sealed, "seal")
        XCTAssertEqual(try box.openAnswer(sealed), plaintext, "open")
        XCTAssertEqual(try ClubSealing.open(sealed, as: .post, in: box.invite.credentials), plaintext, "ClubClient opens it too")
    }

    func testAReplyPartDoesNotOpenAsAPreviewOrWithAnotherKey() throws {
        let box = ReplyBox.random()
        let linkKey = ShareLinkSealing.Key.random()
        let sealed = try box.sealedReplyPart(linkKey: linkKey)
        XCTAssertThrowsError(try ShareLinkSealing.open(sealed, as: .preview, key: linkKey))
        XCTAssertThrowsError(try ReplyBox.openReplyPart(sealed, linkKey: .random()))
        var flipped = sealed
        flipped[flipped.count - 1] ^= 1
        XCTAssertThrowsError(try ReplyBox.openReplyPart(flipped, linkKey: linkKey))
    }

    func testAReplyPartWithUnknownKeysOpensAndAWrongVersionDoesNot() throws {
        let linkKey = ShareLinkSealing.Key.random()
        let box = ReplyBox.random()
        let extra = #"{"box":"\#(box.id)","later":{"x":1},"post":"\#(box.credentials.postProof)","seal":"\#(box.sealKeyBase64URL)","v":1}"#
        let sealedExtra = try ShareLinkSealing.seal(Data(extra.utf8), as: .reply, key: linkKey)
        XCTAssertEqual(try ReplyBox.openReplyPart(sealedExtra, linkKey: linkKey), box.part)
        let v2 = extra.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)
        XCTAssertThrowsError(try ReplyBox.openReplyPart(try ShareLinkSealing.seal(Data(v2.utf8), as: .reply, key: linkKey), linkKey: linkKey))
    }

    func testABoxNeverPrintsItsSecrets() {
        let box = ReplyBox.random()
        let record = sampleRecord(box: box)
        for text in [String(describing: box), String(reflecting: box), String(describing: record)] {
            XCTAssertFalse(text.contains(box.key.fragment))
            XCTAssertFalse(text.contains(box.credentials.readProof))
        }
    }

    // MARK: The record

    private func date(_ days: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + days * 86_400) }

    private func sampleRecord(box: ReplyBox = ReplyBox.random(), answers: [ReplyBoxRecord.Answer] = []) -> ReplyBoxRecord {
        ReplyBoxRecord(
            box: box, linkId: "0123456789abcdef0123456789abcdef", itemId: "item-1", sharedPackageDigest: "sha256:shared",
            createdAt: date(0), expiresAt: date(30), answers: answers
        )
    }

    func testTheRecordGivesBackItsBoxAndRefusesADamagedKey() {
        let box = ReplyBox.random()
        var record = sampleRecord(box: box)
        XCTAssertEqual(record.box, box)
        XCTAssertEqual(record.id, box.id)
        record.key = ReplyBox.Key.random().fragment
        XCTAssertNil(record.box, "a key that is not this box's opens nothing")
        record.key = "not a key"
        XCTAssertNil(record.box)
    }

    func testTheReadWindowAndAClosedBoxGetOneLastCheck() {
        var record = sampleRecord()
        XCTAssertTrue(record.isOpenForChecks(at: date(1)))
        XCTAssertTrue(record.isOpenForChecks(at: date(36.9)), "answers can be fetched 7 days after the link ends")
        XCTAssertFalse(record.isOpenForChecks(at: date(37)))
        record = record.markingClosed(at: date(5))
        XCTAssertEqual(record.closedAt, date(5))
        XCTAssertEqual(record.markingClosed(at: date(9)).closedAt, date(5), "closing twice keeps the first time")
        record.lastChecked = date(4)
        XCTAssertTrue(record.isOpenForChecks(at: date(6)), "one check after the close collects what came before it")
        record.lastChecked = date(5.5)
        XCTAssertFalse(record.isOpenForChecks(at: date(6)))
        var ended = sampleRecord()
        ended.ended = true
        XCTAssertFalse(ended.isOpenForChecks(at: date(1)))
    }

    func testRetentionKeepsARecordWhileAnyAnswerIsInTheLibrary() {
        let record = sampleRecord(answers: [.init(seq: 1, layerId: "layer-a"), .init(seq: 2, layerId: "layer-b")])
        XCTAssertFalse(record.shouldDelete(at: date(36), layerIsInLibrary: { _ in false }), "inside the read window")
        XCTAssertFalse(record.shouldDelete(at: date(40), layerIsInLibrary: { $0 == "layer-b" }), "Report keeps working")
        XCTAssertTrue(record.shouldDelete(at: date(40), layerIsInLibrary: { _ in false }))
        XCTAssertTrue(sampleRecord().shouldDelete(at: date(37), layerIsInLibrary: { _ in true }), "no answers, nothing to keep")
        XCTAssertTrue(record.carries(layerId: "layer-a"))
        XCTAssertFalse(record.carries(layerId: "layer-c"))
    }

    func testARecordFromALaterBuildOrWithoutOptionalFieldsStillReads() throws {
        let encoded = try JSONEncoder().encode(sampleRecord(answers: [.init(seq: 1, layerId: "l")]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["later"] = ["x": 1]
        var answers = try XCTUnwrap(object["answers"] as? [[String: Any]])
        answers.append(["seq": "not a number"])
        object["answers"] = answers
        object.removeValue(forKey: "cursor")
        object.removeValue(forKey: "closed")
        object.removeValue(forKey: "ended")
        let decoded = try JSONDecoder().decode(ReplyBoxRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.answers, [.init(seq: 1, layerId: "l")])
        XCTAssertEqual(decoded.cursor, 0)
        XCTAssertFalse(decoded.closed)
        XCTAssertFalse(decoded.ended)
    }

    func testTheServersExpiryReadsWithAnyFractionalDigits() {
        let whole = ReplyBoxRecord.parseServerDate("2026-12-03T00:00:00Z")
        XCTAssertEqual(whole, Date(timeIntervalSince1970: 1_796_256_000))
        XCTAssertEqual(ReplyBoxRecord.parseServerDate("2026-12-03T00:00:00.5Z")?.timeIntervalSince1970 ?? 0, 1_796_256_000.5, accuracy: 0.001)
        XCTAssertEqual(ReplyBoxRecord.parseServerDate("2026-12-03T00:00:00.123456789Z")?.timeIntervalSince1970 ?? 0, 1_796_256_000.123, accuracy: 0.001)
        XCTAssertEqual(ReplyBoxRecord.parseServerDate("2026-12-03T01:00:00.123456789+01:00")?.timeIntervalSince1970 ?? 0, 1_796_256_000.123, accuracy: 0.001)
        XCTAssertNil(ReplyBoxRecord.parseServerDate(""))
        XCTAssertNil(ReplyBoxRecord.parseServerDate("tomorrow"))
    }

    // MARK: Only answers to the shared item get in

    func testTheAdmissionRuleTable() {
        let record = sampleRecord()
        func check(_ placed: String?, _ parents: [String], _ route: SharedPacketArrival.Route = .openItem) -> ReplyBoxAdmission.DropReason? {
            ReplyBoxAdmission.check(record: record, placedItemId: placed, parentPackageDigests: parents, route: route)
        }
        XCTAssertNil(check("item-1", []), "a packet on the shared item naming no parent")
        XCTAssertNil(check("item-1", ["sha256:shared", "sha256:shared"]), "every parent in the shared package")
        XCTAssertEqual(check("item-2", []), .otherItem)
        XCTAssertEqual(check(nil, []), .itemMissing, "the sender deleted the shared item")
        XCTAssertEqual(check("item-1", ["sha256:other"]), .otherParent)
        XCTAssertEqual(check("item-1", ["sha256:shared", "sha256:other"]), .otherParent, "one stray parent is enough")
        XCTAssertEqual(check("item-1", ["SHA256:SHARED"]), .otherParent, "digests compare exactly")
        XCTAssertEqual(check("item-1", [""]), .otherParent)
        XCTAssertEqual(check("item-1", [], .review), .needsReview)
        XCTAssertEqual(check("item-2", ["sha256:other"], .review), .otherItem, "the item is checked first")
        XCTAssertEqual(check("ITEM-1", []), .otherItem)
    }

    func testTheAdmissionRuleReadsTheConversationArtifact() {
        let record = sampleRecord()
        let good = MarginConversationArtifact(replies: [.init(
            packageScopedId: "m1",
            link: MarginReplyLink(conversationId: "c", parentPackageDigest: "sha256:shared", parentPackageScopedId: "p1")
        )])
        let stray = MarginConversationArtifact(replies: [.init(
            packageScopedId: "m1",
            link: MarginReplyLink(conversationId: "c", parentPackageDigest: "sha256:else", parentPackageScopedId: "p1")
        )])
        XCTAssertNil(ReplyBoxAdmission.check(record: record, placedItemId: "item-1", conversation: good, route: .openItem))
        XCTAssertNil(ReplyBoxAdmission.check(record: record, placedItemId: "item-1", conversation: nil, route: .openItem))
        XCTAssertEqual(ReplyBoxAdmission.check(record: record, placedItemId: "item-1", conversation: stray, route: .openItem), .otherParent)
    }

    func testEveryDropReasonHasADiagnosticsLineWithNoContent() {
        let codes = ReplyBoxAdmission.DropReason.allCases.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        for reason in ReplyBoxAdmission.DropReason.allCases {
            XCTAssertEqual(reason.diagnosticsLine, "reply_box.dropped reason=\(reason.code)")
            XCTAssertTrue(reason.code.allSatisfy { $0.isLowercase || $0 == "_" })
        }
    }
}
