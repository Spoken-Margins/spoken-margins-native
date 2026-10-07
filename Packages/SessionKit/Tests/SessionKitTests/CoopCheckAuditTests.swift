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

    private func check(_ packets: [OpenedPacket]) throws {
        var report = CoopCheck.Report()
        try CoopCheck.checkOrders(packets, report: &report)
        XCTAssertTrue(report.passed, report.text)
    }

    private func packet(_ digest: String, sender: String? = "Ada", voiceMs: Int? = nil, quote: String? = nil) throws -> OpenedPacket {
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
            editionFingerprintSpines: [], transcriptPhraseSketches: [], embeddedTextItems: [], extractedAssetURLs: [:]
        )
        return OpenedPacket(url: URL(fileURLWithPath: "/\(digest).spokenmargins"), contents: contents, assetFolder: FileManager.default.temporaryDirectory)
    }
}
