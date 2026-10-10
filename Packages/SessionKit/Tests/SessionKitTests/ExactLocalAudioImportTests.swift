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

    // MARK: Guards that keep a wrong file from receiving Margins (#1045, NAR-04)

    private func identity(_ type: SharedItemType = .other, digest: String?, duration: Int? = 10_000) -> SharedItemIdentity {
        SharedItemIdentity(itemType: type, title: "Introduction", durationMs: duration, exactEditionSHA256: digest)
    }

    func testOnlyAFullLengthDigestEverMatches() {
        for placeholder in ["", "unknown", String(repeating: "a", count: 63), String(repeating: "a", count: 65)] {
            XCTAssertFalse(
                ExactLocalAudioImport.matches(identity(digest: placeholder), identity(digest: placeholder)),
                "a \(placeholder.count)-character digest is equal on both sides but is not a SHA-256"
            )
        }
        XCTAssertTrue(ExactLocalAudioImport.matches(identity(digest: digest), identity(digest: digest)))
        XCTAssertFalse(ExactLocalAudioImport.matches(identity(digest: nil), identity(digest: digest)))
        XCTAssertFalse(ExactLocalAudioImport.matches(identity(digest: digest), identity(digest: nil)))
        XCTAssertFalse(ExactLocalAudioImport.matches(identity(digest: nil), identity(digest: nil)))
    }

    func testDurationsMustAgreeWithinAQuarterSecondAndExist() {
        XCTAssertTrue(ExactLocalAudioImport.matches(identity(digest: digest, duration: 10_000), identity(digest: digest, duration: 10_250)))
        XCTAssertTrue(ExactLocalAudioImport.matches(identity(digest: digest, duration: 10_250), identity(digest: digest, duration: 10_000)))
        XCTAssertFalse(ExactLocalAudioImport.matches(identity(digest: digest, duration: 10_000), identity(digest: digest, duration: 10_251)))
        XCTAssertFalse(ExactLocalAudioImport.matches(identity(digest: digest, duration: 10_251), identity(digest: digest, duration: 10_000)))
        for unusable: Int? in [nil, 0, -5] {
            XCTAssertFalse(ExactLocalAudioImport.matches(identity(digest: digest, duration: unusable), identity(digest: digest, duration: unusable)), "\(String(describing: unusable))")
            XCTAssertFalse(ExactLocalAudioImport.matches(identity(digest: digest), identity(digest: digest, duration: unusable)), "\(String(describing: unusable))")
        }
    }

    func testOnlyLocalAudioTakesTheExactEditionPath() {
        for type in [SharedItemType.text, .podcast, .pdf, .epub] {
            XCTAssertFalse(ExactLocalAudioImport.matches(identity(type, digest: digest), identity(digest: digest)), "\(type) shared, local audio here")
            XCTAssertFalse(ExactLocalAudioImport.matches(identity(digest: digest), identity(type, digest: digest)), "local audio shared, \(type) here")
            XCTAssertFalse(ExactLocalAudioImport.matches(identity(type, digest: digest), identity(type, digest: digest)), "\(type) on both sides")
        }
    }

    func testAnAnchorBeforeTheStartOfTheAudioIsUnresolved() {
        let source = identity(digest: digest), recipient = identity(digest: digest)
        for time in [-1, -3_250] {
            let anchor = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: time)
            XCTAssertEqual(ExactLocalAudioImport.resolution(anchor: anchor, source: source, recipient: recipient).evidenceClass, .unresolved, "\(time)")
        }
        for time in [0, 9_999] {
            let resolution = ExactLocalAudioImport.resolution(anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: time), source: source, recipient: recipient)
            XCTAssertEqual(resolution.evidenceClass, .exactEdition, "\(time)")
            XCTAssertEqual(resolution.localMediaTimeMs, time)
        }
    }

    func testProjectionRejectsTwoScenesWithTheSameId() {
        let twins = map([scene("a", order: 0, start: 0, end: 5_000), scene("a", order: 1, start: 5_000, end: 10_000)])
        XCTAssertThrowsError(try ExactLocalAudioImport.projection(proposal: twins, source: item(), recipient: item(), itemId: "local"))
    }

    func testProjectionRejectsAnEligibleSceneWithNoGroundedSummary() throws {
        func eligible(text: String?, provenance: PortableSummaryProvenance?) -> PortableListeningMapProposalArtifact {
            map([PortableListeningMapScene(
                id: "a", order: 0, title: "a", summaryText: text, summaryProvenance: provenance, eligibility: .eligible,
                startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0),
                endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 5_000)
            )])
        }
        XCTAssertNoThrow(try ExactLocalAudioImport.projection(proposal: eligible(text: "A bounded summary.", provenance: .modelGenerated), source: item(), recipient: item(), itemId: "local"))
        for ungrounded in [eligible(text: nil, provenance: .modelGenerated), eligible(text: " \n ", provenance: .modelGenerated), eligible(text: "A bounded summary.", provenance: nil)] {
            XCTAssertThrowsError(try ExactLocalAudioImport.projection(proposal: ungrounded, source: item(), recipient: item(), itemId: "local"))
        }
        // An excluded scene carries no summary on purpose; only eligible scenes need one.
        let excluded = map([PortableListeningMapScene(
            id: "a", order: 0, eligibility: .excluded,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 5_000)
        )])
        XCTAssertNoThrow(try ExactLocalAudioImport.projection(proposal: excluded, source: item(), recipient: item(), itemId: "local"))
    }
}
