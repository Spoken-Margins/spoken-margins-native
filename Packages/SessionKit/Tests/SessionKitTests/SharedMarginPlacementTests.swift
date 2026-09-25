import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// Placing an unplaced shared podcast Margin by ear (#158).
final class SharedMarginPlacementTests: XCTestCase {
    private func margin(
        senderMs: Int?,
        resolution: ImportedAnchorResolution = .init(evidenceClass: .unresolved)
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "imported-1",
            layerId: "layer-1",
            packageScopedId: "pkg::ij-004",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: senderMs),
            approvedTranscript: "All right, this is my 4th margin",
            resolution: resolution
        )
    }

    func testUnplacedMarginSuggestsTheSendersTimeWithALeadIn() throws {
        let placement = try XCTUnwrap(SharedMarginPlacement(interjection: margin(senderMs: 470_752)))
        XCTAssertEqual(placement.suggestedMediaTimeMs, 470_752)
        XCTAssertEqual(placement.listenStartMediaTimeMs, 455_752)
        XCTAssertEqual(placement.suggestionSource, .senderTimestamp)
        XCTAssertEqual(placement.layerId, "layer-1")
        XCTAssertEqual(placement.interjectionId, "imported-1")
    }

    func testApproximateMatchIsPreferredOverTheSendersTime() throws {
        let approximate = ImportedAnchorResolution(evidenceClass: .timestampFallback, localMediaTimeMs: 500_000)
        let placement = try XCTUnwrap(SharedMarginPlacement(interjection: margin(senderMs: 470_752, resolution: approximate)))
        XCTAssertEqual(placement.suggestedMediaTimeMs, 500_000)
        XCTAssertEqual(placement.suggestionSource, .approximateMatch)

        let ambiguous = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 900_000, isAmbiguous: true)
        let fromSender = try XCTUnwrap(SharedMarginPlacement(interjection: margin(senderMs: 470_752, resolution: ambiguous)))
        XCTAssertEqual(fromSender.suggestedMediaTimeMs, 470_752, "an ambiguous match isn't a suggestion")
    }

    func testStartsAtZeroNearTheBeginningAndStaysInsideAShorterEdition() throws {
        XCTAssertEqual(SharedMarginPlacement(interjection: margin(senderMs: 4_000))?.listenStartMediaTimeMs, 0)
        let clamped = try XCTUnwrap(SharedMarginPlacement(interjection: margin(senderMs: 2_406_600), recipientDurationMs: 1_927_000))
        XCTAssertEqual(clamped.suggestedMediaTimeMs, 1_927_000)
    }

    func testNothingToSuggestForPlacedMarginsOrMissingTimes() {
        XCTAssertNil(SharedMarginPlacement(interjection: margin(senderMs: nil)))
        for placed in [AnchorResolutionEvidenceClass.acousticVerified, .transcriptVerified, .exactEdition, .fused, .recipientConfirmed] {
            let resolution = ImportedAnchorResolution(evidenceClass: placed, localMediaTimeMs: 470_000)
            XCTAssertNil(SharedMarginPlacement(interjection: margin(senderMs: 470_752, resolution: resolution)), "\(placed)")
        }
    }

    func testConfirmedPositionIsStoredAsRecipientConfirmedAndSurvivesTheDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "shared-placement-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)

        var record = margin(senderMs: 470_752)
        try store.saveImportedCommentaryInterjection(record)
        let placement = try XCTUnwrap(SharedMarginPlacement(interjection: record))
        record.resolution = placement.confirmedResolution(atMediaTimeMs: 498_300)
        try store.saveImportedCommentaryInterjection(record)

        let reloaded = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: "layer-1").first)
        XCTAssertEqual(reloaded.resolution.evidenceClass, .recipientConfirmed)
        XCTAssertEqual(reloaded.resolution.localMediaTimeMs, 498_300)
        XCTAssertFalse(reloaded.resolution.isAmbiguous)
        XCTAssertNil(reloaded.resolution.confidence, "a confirmation by ear claims no measured confidence")
        XCTAssertNil(SharedMarginPlacement(interjection: reloaded), "once confirmed, it isn't offered again")
        XCTAssertEqual(reloaded.anchorEvidence.mediaTimeMs, 470_752, "the sender's evidence is kept as it was")
    }
}
