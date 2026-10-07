import Foundation
import SessionKit
@testable import SessionKitSharing
@testable import CoopPacket
import XCTest

final class CoopCheckAuditTests: XCTestCase {
    // Packet metadata only; no audio encoder/player. Real text archive/Build 29 round trips
    // are exercised by CoopResendTests.
    func testAuditCheckerAcceptsDistinctVoiceDurations() throws {
        try check([packet("O", voiceMs: 4_000), packet("U", voiceMs: 5_000)])
    }

    func testAuditCheckerAcceptsAbsentAndWhitespaceSenders() throws {
        for sender: String? in [nil, "", " \n\t"] {
            try check([packet("O", sender: sender), packet("U", sender: sender)])
        }
    }

    func testAuditCheckerAcceptsDifferentAnchorContext() throws {
        try check([packet("O", quote: "first context"), packet("U", quote: "second context")])
    }

    // A held copy keeps the reply links of whichever packet came first, so a Margin shared twice with
    // its parents listed in a different order must give the same outcome whichever packet that was.
    // Neighbours: both parents present, one parent missing, three parents, two Margins that really
    // answer different parents.
    func testAuditCheckerAcceptsReorderedForkLinksInEveryOrder() throws {
        try check([
            packet("A", sender: "Ada"), packet("C", sender: "Chris"),
            packet("B1", sender: "Ben", links: [link(to: "A"), link(to: "C")]),
            packet("B2", sender: "Ben", links: [link(to: "C"), link(to: "A")])
        ], orders: 24)
    }

    func testAuditCheckerAcceptsReorderedForkLinksWithAMissingParent() throws {
        try check([
            packet("A", sender: "Ada"),
            packet("B1", sender: "Ben", links: [link(to: "A"), link(to: "Z")]),
            packet("B2", sender: "Ben", links: [link(to: "Z"), link(to: "A")])
        ], orders: 6)
    }

    func testAuditCheckerAcceptsReorderedForkLinksOfThreeParents() throws {
        try check([
            packet("A", sender: "Ada"), packet("C", sender: "Chris"), packet("D", sender: "Dee"),
            packet("B1", sender: "Ben", links: [link(to: "A"), link(to: "C"), link(to: "D")]),
            packet("B2", sender: "Ben", links: [link(to: "D"), link(to: "A"), link(to: "C")])
        ], orders: 120)
    }

    func testAuditCheckerKeepsBothMarginsThatAnswerDifferentParents() throws {
        let report = try check([
            packet("A", sender: "Ada"), packet("C", sender: "Chris"), packet("D", sender: "Dee"),
            packet("B1", sender: "Ben", links: [link(to: "A"), link(to: "C")]),
            packet("B2", sender: "Ben", links: [link(to: "A"), link(to: "D")])
        ], orders: 120)
        XCTAssertTrue(report.text.contains("5 held Margin(s)"), report.text)
    }

    @discardableResult
    private func check(_ packets: [OpenedPacket], orders: Int? = nil) throws -> CoopCheck.Report {
        var report = CoopCheck.Report()
        try CoopCheck.checkOrders(packets, report: &report)
        XCTAssertTrue(report.passed, report.text)
        if let orders { XCTAssertTrue(report.text.contains("\(orders) orders"), report.text) }
        return report
    }

    private func link(to digest: String) -> MarginReplyLink {
        MarginReplyLink.replying(to: MarginPacketIdentity(packageDigest: digest, packageScopedId: "margin-0001"), parentConversationId: nil)
    }

    private func packet(
        _ digest: String, sender: String? = "Ada", voiceMs: Int? = nil, quote: String? = nil, links: [MarginReplyLink] = []
    ) throws -> OpenedPacket {
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-\(digest)", createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            item: SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.org/episode", title: "Episode"),
            itemTransportSelection: .reference,
            selections: [ReviewedInterjectionSelection(
                packageScopedId: "margin-0001",
                revision: InterjectionShareRevision(
                    id: "revision-\(digest)", interjectionId: "ij-001", itemId: "source-item",
                    sessionId: "session-source-11111111-1111-4111-8111-111111111111",
                    createdAt: Date(timeIntervalSince1970: 1_777_000_000), approvedTranscript: "Agreed",
                    anchorBefore: "", anchorAfter: "", status: .senderApproved
                ),
                anchor: PortableAnchorEvidence(anchorType: .media, exactText: quote, mediaTimeMs: 60_000),
                representation: voiceMs.map { .originalAudio(sourceURL: URL(fileURLWithPath: "/metadata-only.m4a"), durationMs: $0) } ?? .textOnly
            )], senderDisplayLabel: sender
        )
        var manifest = prepared.manifest
        manifest.contentDigest = digest
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let commentary = try XCTUnwrap(prepared.artifactData.values.compactMap { try? decoder.decode(SharedCommentaryLayerArtifact.self, from: $0) }.first)
        let contents = VerifiedSpokenMarginsPackage(
            manifest: manifest, commentaryLayers: [commentary], listeningMapProposals: [],
            editionFingerprintSpines: [], transcriptPhraseSketches: [], embeddedTextItems: [],
            conversations: links.isEmpty ? [] : [MarginConversationArtifact(replies: links.map { .init(packageScopedId: "margin-0001", link: $0) })],
            extractedAssetURLs: [:]
        )
        return OpenedPacket(url: URL(fileURLWithPath: "/\(digest).spokenmargins"), contents: contents, assetFolder: FileManager.default.temporaryDirectory)
    }
}
