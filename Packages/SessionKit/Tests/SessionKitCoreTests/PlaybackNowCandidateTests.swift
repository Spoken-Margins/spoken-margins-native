import Foundation
import XCTest
@testable import SessionKit

final class PlaybackNowCandidateTests: XCTestCase {
    func testOwnMarginsKeepSessionsDistinctAndUseSeconds() throws {
        let first = try XCTUnwrap(PlaybackNowMargins.Margin(own: own(session: "old"), itemID: "episode"))
        let second = try XCTUnwrap(PlaybackNowMargins.Margin(own: own(session: "new"), itemID: "episode"))
        XCTAssertEqual(first.id, "old::note")
        XCTAssertEqual(second.id, "new::note")
        XCTAssertEqual(first.position, 80)
        XCTAssertEqual(first.origin, .own)
        XCTAssertFalse(first.isApproximate)
        XCTAssertEqual(PlaybackNowMargins.rows(playhead: 70, margins: [first, second]).count, 2)
    }

    func testOwnCandidatesExcludeOtherItemsDeletedAndResponseMargins() {
        var note = own()
        XCTAssertNil(PlaybackNowMargins.Margin(own: note, itemID: "other"))
        note.status = "deleted"
        XCTAssertNil(PlaybackNowMargins.Margin(own: note, itemID: "episode"))
        note.status = "active"
        for target in [InterjectionTargetType.assistantTurn, .summaryTurn] {
            note.targetType = target
            XCTAssertNil(PlaybackNowMargins.Margin(own: note, itemID: "episode"))
        }
    }

    func testMissingAndNegativeOwnTimesAreNotInventedFromPercent() {
        for time in [Int?.none, -1] {
            var note = own()
            note.anchor.mediaTimeMs = time
            XCTAssertNil(PlaybackNowMargins.Margin(own: note, itemID: "episode"))
        }
    }

    func testSharedCandidateUsesTheSamePositionAsPlayingTheMoment() throws {
        let layer = layer()
        for resolution in [
            ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 90_000),
            .init(evidenceClass: .mapInterpolated, localMediaTimeMs: 90_000),
            .init(evidenceClass: .acousticVerified, localMediaTimeMs: 90_000, isAmbiguous: true),
            .init(evidenceClass: .unresolved)
        ] {
            let note = shared(resolution)
            let position = try XCTUnwrap(SharedMarginPlaybackPosition(note))
            let candidate = try XCTUnwrap(PlaybackNowMargins.Margin(shared: note, layer: layer, itemID: "episode"))
            XCTAssertEqual(candidate.id, "shared::layer::note")
            XCTAssertEqual(candidate.position, Double(position.mediaTimeMs) / 1_000)
            XCTAssertEqual(candidate.isApproximate, position.isApproximate)
            XCTAssertEqual(candidate.origin, .shared)
        }
    }

    func testDeletedUnrelatedAndUnpositionedSharedMarginsAreExcluded() {
        var layer = layer()
        let note = shared(.init(evidenceClass: .unresolved))
        XCTAssertNil(PlaybackNowMargins.Margin(shared: note, layer: layer, itemID: "other"))
        layer.deletedAt = Date()
        XCTAssertNil(PlaybackNowMargins.Margin(shared: note, layer: layer, itemID: "episode"))
        let unplaced = ImportedCommentaryInterjection(
            id: "unplaced", layerId: "layer", packageScopedId: "pkg::unplaced", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Text only",
            resolution: .init(evidenceClass: .unresolved))
        XCTAssertNil(PlaybackNowMargins.Margin(shared: unplaced, layer: self.layer(), itemID: "episode"))
    }

    private func own(session: String = "session") -> Interjection {
        Interjection(id: "note", itemId: "episode", sessionId: session, targetType: .item,
                     targetId: "episode", createdAt: Date(), roughPercent: 25,
                     anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 80_000), audioPath: nil,
                     audioStatus: "saved", transcriptionStatus: "complete", transcript: "Own note", cleanedTranscript: nil, displayText: nil, status: "active")
    }

    private func shared(_ resolution: ImportedAnchorResolution) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(id: "note", layerId: "layer", packageScopedId: "pkg::note",
            createdAt: Date(), anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 80_000),
            approvedTranscript: "A shared note", resolution: resolution)
    }

    private func layer() -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(id: "layer", itemId: "episode", packageDigest: "digest", packageId: "pkg",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"), importedAt: Date())
    }
}
