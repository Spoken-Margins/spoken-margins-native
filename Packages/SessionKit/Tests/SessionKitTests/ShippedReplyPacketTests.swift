import Foundation
import SessionKit
import SessionKitSharing
import XCTest

/// A reply packet this build writes is the packet Builds 32 and 34 write, so both read its reply link (#473).
///
/// `Fixtures/build34-reply-packet.spokenmargins` was written on 2026-10-26 by the SessionKit and SessionKitSharing
/// sources at `testflight/0.1-build-34`, built on their own with the inputs in `writeReplyPacket`. The sources at
/// `testflight/0.1-build-32` wrote the same bytes. Each of Builds 32, 34 and this build then read every one of the three
/// packets and found Margins b-1 and b-2 with b-1's link to a-1 intact. The frozen reader in these tests is Build 29's,
/// which ignores reply links (`MarginReplyPacketTests`); this fixture is what holds the later builds to the format.
///
/// If `testThisBuildWritesTheReplyPacketBuilds32And34Write` fails, the packet format changed. Don't regenerate the
/// fixture from this build: build the two tags' sources (as `scripts/freeze-shipped-reader.sh` copies them) with the
/// inputs below, check that both still read this build's packet and its reply link, and say so in the PR.
final class ShippedReplyPacketTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/build34-reply-packet.spokenmargins")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShippedReplyPacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func selection(_ id: String, _ text: String, replyTo: MarginReplyLink?) -> ReviewedInterjectionSelection {
        .init(
            packageScopedId: id,
            revision: InterjectionShareRevision(
                id: "revision-\(id)", interjectionId: "private-\(id)", itemId: "private-item", sessionId: "private-session",
                createdAt: created, approvedTranscript: text,
                anchorBefore: "Before.", anchorAfter: "After.", status: .senderApproved
            ),
            anchor: .init(anchorType: .text, exactText: "The durable idea."),
            representation: .textOnly,
            replyTo: replyTo
        )
    }

    /// One reply to a friend's Margin a-1 and one ordinary Margin: the shape a Margin recorded during a friend's
    /// Margin takes in a packet.
    private func writeReplyPacket(to url: URL) throws {
        let link = MarginReplyLink(
            conversationId: "conversation-1", parentPackageDigest: String(repeating: "a", count: 64), parentPackageScopedId: "a-1"
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-b", createdAt: created,
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article"),
            itemTransportSelection: .reference,
            selections: [selection("b-1", "I disagree.", replyTo: link), selection("b-2", "Unrelated note.", replyTo: nil)],
            senderDisplayLabel: "B", suggestedRevealMode: .companion
        )
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
    }

    func testThisBuildWritesTheReplyPacketBuilds32And34Write() throws {
        let url = root.appendingPathComponent("current.spokenmargins")
        try writeReplyPacket(to: url)
        XCTAssertEqual(
            try Data(contentsOf: url), try Data(contentsOf: fixture),
            "the reply packet's bytes differ from what Builds 32 and 34 write; see this class's comment before changing the fixture"
        )
    }

    func testThisBuildReadsBuild34sReplyPacketWithItsLink() throws {
        let packet = try SpokenMarginsPackageArchive.read(from: fixture, extractingAssetsTo: root.appendingPathComponent("assets"))
        XCTAssertEqual(packet.commentaryLayers.flatMap { $0.interjections.map(\.packageScopedId) }.sorted(), ["b-1", "b-2"])
        XCTAssertEqual(packet.conversations.flatMap(\.replies).map(\.packageScopedId), ["b-1"])
        XCTAssertEqual(packet.conversations.first?.linksByPackageScopedId["b-1"], [MarginReplyLink(
            conversationId: "conversation-1", parentPackageDigest: String(repeating: "a", count: 64), parentPackageScopedId: "a-1"
        )])
        let descriptor = try XCTUnwrap(packet.manifest.artifacts.first { $0.kind == SpokenMarginsArtifactKind.conversation })
        XCTAssertFalse(descriptor.required, "a required conversation artifact would lock Build 29 out")
    }
}
