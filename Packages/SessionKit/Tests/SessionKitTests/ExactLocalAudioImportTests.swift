import XCTest
import SessionKit
import SessionKitSharing

final class ExactLocalAudioImportTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private func item(_ hash: String? = nil, duration: Int = 10_000) -> SharedItemIdentity {
        SharedItemIdentity(itemType: .other, title: "Introduction", durationMs: duration, exactEditionSHA256: hash ?? digest)
    }
    private func scene(_ id: String, order: Int, start: Int, end: Int) -> PortableListeningMapScene {
        PortableListeningMapScene(id: id, order: order, title: id, summaryText: "A bounded summary.", summaryProvenance: .modelGenerated, eligibility: .eligible,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: start),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: end))
    }
    private func map(_ scenes: [PortableListeningMapScene]) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(id: "map", createdAt: Date(), generator: "test", scenes: scenes)
    }
    func testExactMediaAnchorResolvesWithoutTranscriptAndRejectsWrongBytes() {
        let anchor = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 3_250)
        let resolution = ExactLocalAudioImport.resolution(anchor: anchor, source: item(), recipient: item())
        XCTAssertEqual(resolution.evidenceClass, .exactEdition)
        XCTAssertEqual(resolution.localMediaTimeMs, 3_250)
        XCTAssertEqual(ExactLocalAudioImport.resolution(anchor: anchor, source: item(), recipient: item(String(repeating: "b", count: 64))).evidenceClass, .unresolved)
        XCTAssertFalse(ExactLocalAudioImport.matches(item(), item(duration: 11_000)))
    }
    func testBoundsAndAnchorTypeCannotBePromotedByMatchingDigest() {
        for anchor in [PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 10_000), PortableAnchorEvidence(anchorType: .text, mediaTimeMs: 3_000)] {
            XCTAssertEqual(ExactLocalAudioImport.resolution(anchor: anchor, source: item(), recipient: item()).evidenceClass, .unresolved)
        }
    }
    func testProjectionRejectsOverlapWrongOrderAndOutOfRange() throws {
        let first = scene("a", order: 0, start: 0, end: 5_000)
        let good = map([first, scene("b", order: 1, start: 5_000, end: 10_000)])
        let projected = try ExactLocalAudioImport.projection(proposal: good, source: item(), recipient: item(), itemId: "local")
        XCTAssertEqual(projected.projectedRecipientTime(for: 5_000), 5_000)
        for bad in [map([first, scene("b", order: 1, start: 4_999, end: 10_000)]), map([first, scene("b", order: 2, start: 5_000, end: 10_000)]), map([first, scene("b", order: 1, start: 5_000, end: 10_001)])] {
            XCTAssertThrowsError(try ExactLocalAudioImport.projection(proposal: bad, source: item(), recipient: item(), itemId: "local"))
        }
        XCTAssertThrowsError(try ExactLocalAudioImport.projection(proposal: good, source: item(), recipient: item(String(repeating: "b", count: 64)), itemId: "local"))
    }
    func testImporterUsesExactLocalMediaPathAndRetainsPerMarginFailure() {
        let records = [1_000, 15_000].enumerated().map { index, time in
            SharedInterjectionPackageRecord(packageScopedId: "m-\(index)", createdAt: Date(), anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: time), defaultRepresentationId: "text", representations: [SharedInterjectionRepresentation(id: "text", kind: .textOnly, approvedTranscript: "Question", provenance: .senderApprovedTextOnly)])
        }
        let result = ImportedItemResolver.resolve(item: item(), interjections: records, against: item(), itemText: nil)
        XCTAssertEqual(result.status, .contextOnly)
        XCTAssertEqual(result.anchorsByPackageScopedId["m-0"]?.localMediaTimeMs, 1_000)
        XCTAssertEqual(result.anchorsByPackageScopedId["m-1"]?.evidenceClass, .unresolved)
        XCTAssertEqual(ImportedItemResolver.resolve(item: item(), interjections: records, against: item(String(repeating: "b", count: 64)), itemText: nil).status, .wrongSource)
    }
}
