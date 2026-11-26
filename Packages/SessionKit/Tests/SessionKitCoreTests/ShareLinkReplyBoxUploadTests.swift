import Foundation
import XCTest
@testable import SessionKit

/// The link upload carrying a reply box (#4675, piece 3): four headers, all or none; a nil box sends today's request;
/// a record only when the server says `"replyBox": true`.
final class ShareLinkReplyBoxUploadTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        struct Sent { let url: URL; let contentType: String; let headers: [String: String]; let body: Data }
        private let lock = NSLock()
        private var stored: [Sent] = []
        var requests: [Sent] { lock.withLock { stored } }
        func add(_ sent: Sent) { lock.withLock { stored.append(sent) } }
    }

    private let key = ShareLinkSealing.Key(bytes: Data((0..<32).map { UInt8($0) }))!
    private let linkId = "0123456789abcdef0123456789abcdef"

    private func client(_ recorder: Recorder, body: String) -> ShareLinkClient {
        let key = self.key
        return ShareLinkClient(
            server: { URL(string: "https://links.example.test\($0)")! }, key: { key }, consent: { true }
        ) { (url: URL, contentType: String, headers: [String: String], data: Data) in
            recorder.add(.init(url: url, contentType: contentType, headers: headers, body: data))
            return (201, Data(body.utf8))
        }
    }

    private func created(replyBox: Bool?) -> String {
        let extra = replyBox.map { #","replyBox":\#($0)"# } ?? ""
        return #"{"id":"\#(linkId)","path":"/l/\#(linkId)","expiresAt":"2026-12-03T00:00:00.123456789Z"\#(extra)}"#
    }

    private func preview() throws -> ShareLinkPreview {
        try ShareLinkPreviewBuilder.make(title: "Harbour", show: nil, pageURL: nil, enclosureURL: nil, marginTexts: ["Listen."])
    }

    /// The body with its random boundary replaced, so two uploads of the same packet compare byte for byte.
    private func normalized(_ sent: Recorder.Sent) throws -> (contentType: String, body: Data) {
        let boundary = try XCTUnwrap(sent.contentType.components(separatedBy: "boundary=").last)
        var body = sent.body
        let needle = Data(boundary.utf8)
        while let range = body.range(of: needle) { body.replaceSubrange(range, with: Data("B".utf8)) }
        return (sent.contentType.replacingOccurrences(of: boundary, with: "B"), body)
    }

    func testANilBoxSendsTodaysRequestByteForByte() async throws {
        let packet = Data("PK packet".utf8)
        let today = Recorder(), withNil = Recorder()
        _ = await client(today, body: created(replyBox: nil)).makeLink(packet: packet, preview: try preview(), linksState: .on)
        let made = await client(withNil, body: created(replyBox: true)).makeLink(
            packet: packet, preview: try preview(), linksState: .on, replyBox: nil
        )
        let a = try XCTUnwrap(today.requests.first), b = try XCTUnwrap(withNil.requests.first)
        XCTAssertEqual(a.url, b.url)
        XCTAssertEqual(a.headers, [:])
        XCTAssertEqual(b.headers, [:])
        // AES-GCM nonces are random, so the sealed parts differ; everything around them must not.
        let left = try normalized(a), right = try normalized(b)
        XCTAssertEqual(left.contentType, right.contentType)
        XCTAssertEqual(left.body.count, right.body.count)
        // Byte for byte outside the two sealed parts: the multipart framing, part names and their order.
        func framing(_ body: Data) -> [Data] {
            var pieces: [Data] = []
            var rest = body[...]
            while let open = rest.range(of: Data("--B".utf8)) {
                let headerEnd = rest.range(of: Data("\r\n\r\n".utf8), in: open.lowerBound..<rest.endIndex)?.upperBound ?? rest.endIndex
                pieces.append(Data(rest[open.lowerBound..<headerEnd]))
                rest = rest[headerEnd...]
            }
            return pieces
        }
        XCTAssertEqual(framing(left.body), framing(right.body))
        XCTAssertEqual(framing(left.body).count, 3)
        XCTAssertNil(made.replyBox, "no box was sent, so none is kept even if a server said so")
        XCTAssertNil(made.replyBoxRecord(itemId: "i", sharedPackageDigest: "d"))
        guard case .link = made.result else { return XCTFail("\(made.result)") }
    }

    func testABoxRidesAsFourHeadersAndIsKeptOnlyWhenTheServerMadeIt() async throws {
        let box = ReplyBox.random()
        let recorder = Recorder()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let made = await client(recorder, body: created(replyBox: true)).makeLink(
            packet: Data("PK".utf8), preview: try preview(), linksState: .on, replyBox: box
        )
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(Set(sent.headers.keys), [ReplyBox.idHeader, ReplyBox.readHashHeader, ReplyBox.postHashHeader, ReplyBox.partHeader])
        XCTAssertEqual(sent.headers[ReplyBox.idHeader], box.id)
        XCTAssertEqual(sent.headers[ReplyBox.readHashHeader], box.credentials.readHash)
        XCTAssertEqual(sent.headers[ReplyBox.postHashHeader], box.credentials.postHash)
        let part = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(sent.headers[ReplyBox.partHeader])))
        XCTAssertEqual(try ReplyBox.openReplyPart(part, linkKey: key), box.part, "sealed with the link's own key")
        XCTAssertNil(sent.body.range(of: Data(box.id.utf8)), "the multipart body is unchanged")

        XCTAssertEqual(made.replyBox, box)
        XCTAssertEqual(made.linkId, linkId)
        let record = try XCTUnwrap(made.replyBoxRecord(itemId: "item-1", sharedPackageDigest: "sha256:shared", now: now))
        XCTAssertEqual(record.boxId, box.id)
        XCTAssertEqual(record.linkId, linkId)
        XCTAssertEqual(record.box, box)
        XCTAssertEqual(record.itemId, "item-1")
        XCTAssertEqual(record.sharedPackageDigest, "sha256:shared")
        XCTAssertEqual(record.expiresAt.timeIntervalSince1970, 1_796_256_000.123, accuracy: 0.001)
        XCTAssertEqual(record.cursor, 0)
    }

    func testA201WithoutReplyBoxTrueKeepsNoBox() async throws {
        for answer in [nil, false] as [Bool?] {
            let made = await client(Recorder(), body: created(replyBox: answer)).makeLink(
                packet: Data("PK".utf8), preview: try preview(), linksState: .on, replyBox: .random()
            )
            guard case .link = made.result else { return XCTFail("the link is still made: \(made.result)") }
            XCTAssertNil(made.replyBox, "replyBox \(String(describing: answer))")
            XCTAssertNil(made.replyBoxRecord(itemId: "i", sharedPackageDigest: "d"))
        }
    }

    func testAFailedUploadKeepsNoBoxAndSaysWhatTodaySays() async throws {
        let key = self.key
        let failing = ShareLinkClient(server: { URL(string: "https://links.example.test\($0)")! }, key: { key }, consent: { true }) { (_: URL, _: String, _: [String: String], _: Data) in
            (429, Data(#"{"error":"rate_limited"}"#.utf8))
        }
        let made = await failing.makeLink(packet: Data("PK".utf8), preview: try preview(), linksState: .on, replyBox: .random())
        XCTAssertEqual(made.result, .useFile(.busy))
        XCTAssertNil(made.replyBox)
        let noConsent = ShareLinkClient(key: { key }, consent: { false }) { (_: URL, _: String, _: [String: String], _: Data) in (201, Data()) }
        let refused = await noConsent.makeLink(packet: Data(), preview: try preview(), linksState: .on, replyBox: .random())
        XCTAssertEqual(refused.result, .needsConsent)
    }
}
