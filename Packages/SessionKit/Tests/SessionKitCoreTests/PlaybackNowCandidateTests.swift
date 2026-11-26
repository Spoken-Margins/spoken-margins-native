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

    /// #5288: a spoken note playing its Shorter pauses version. One 4 s take; the version keeps 0–1 s and 2.5–4 s, so
    /// 3 s on the recording is 1.5 s on the file playing.
    func testOwnMarginOnShorterPausesCountsDownOnTheFilePlaying() throws {
        let take = SpokenNoteWholeAudioLayout.Requested(id: "a", audioFileName: "take-a.m4a", durationMs: 4_000)
        let map = SpokenNoteCleanMap(
            placements: [
                .init(takeId: "a", takeStartMs: 0, takeEndMs: 1_000, outputStartMs: 0),
                .init(takeId: "a", takeStartMs: 2_500, takeEndMs: 4_000, outputStartMs: 1_000),
            ],
            recorded: SpokenNoteWholeAudioLayout(requested: [take], placed: [.init(takeId: "a", startMs: 0, durationMs: 4_000)], durationMs: 4_000),
            cleanDurationMs: 2_500
        )
        var note = own()
        note.anchor.mediaTimeMs = 3_000
        let onVersion = try XCTUnwrap(PlaybackNowMargins.Margin(own: note, itemID: "episode", clock: map))
        XCTAssertEqual(onVersion.position, 1.5)
        XCTAssertNil(PlaybackNowMargins.rows(playhead: 2, margins: [onVersion]).first?.countdown, "passed on the file playing")
        XCTAssertEqual(PlaybackNowMargins.rows(playhead: 1, margins: [onVersion]).first?.countdown, "in 0:01")

        let asRecorded = try XCTUnwrap(PlaybackNowMargins.Margin(own: note, itemID: "episode"))
        XCTAssertEqual(asRecorded.position, 3, "As recorded: the saved time, unchanged")
        XCTAssertEqual(PlaybackNowMargins.rows(playhead: 2, margins: [asRecorded]).first?.countdown, "in 0:01")
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
