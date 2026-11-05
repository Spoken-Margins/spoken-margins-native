import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest
@testable import SpokenMarginsApp

/// #3412 audit: the Timeline's tap on a friend's Margin is `playSharedMarginMoment(row)`. For a written Margin it used to
/// fail, because it asked for a recording the Margin does not have. These drive that call itself, with the row the
/// Timeline builds, a real source player and a real file where the reading would be rendered.
@MainActor
final class WrittenMarginTimelineTapAppTests: XCTestCase {
    /// Each test leaves the shared written-Margin reader idle, so a leak fails the test that made it (#3423).
    override func tearDown() async throws {
        await ReturnFixture.expectSharedReaderIdle()
        try await super.tearDown()
    }

    private func row(_ fixture: ReturnFixture) -> SharedMarginRow {
        SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")
    }

    // The item screen shows Listen from `canListen`. A friend's written Margin has no recording and still gets it (the
    // review of #3412 found it hidden); a voice Margin with a recording keeps it; a note the voice can't read has none.
    func testTheItemScreensSnapshotOffersListenToAFriendsWrittenMarginAsWellAsAVoiceMargin() {
        let layer = ImportedCommentaryLayer(id: "ana", itemId: "item", packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: "Ana", importedAt: Date(), sourceResolutionStatus: .resolved, isEnabled: true)
        func snapshot(audioPath: String?, words: String) -> Build23ImportedMarginSnapshot {
            let margin = ImportedCommentaryInterjection(id: "m", layerId: layer.id, packageScopedId: "m", createdAt: Date(),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: words,
                audioPath: audioPath, audioDurationMs: audioPath == nil ? nil : 4_000,
                resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 60_000, confidence: 1))
            return Build23SharingCoordinator.importedMarginSnapshot(margin, in: layer, placementPass: nil, paragraphs: nil)
        }
        XCTAssertTrue(snapshot(audioPath: nil, words: "Lovely harbour.").canListen, "a written Margin has no recording and can be listened to")
        XCTAssertTrue(snapshot(audioPath: "ana.m4a", words: "Words").canListen, "a voice Margin with a recording still can")
        XCTAssertFalse(snapshot(audioPath: nil, words: "🎧").canListen, "a note the voice cannot read is not offered")
    }

    // A written Margin tapped in the Timeline is heard through the moment: no failure line, a moment starts, and when
    // the moment plays the reading the Margin is marked heard.
    func testTappingAWrittenMarginInTheTimelineHearsItsReadingThroughTheMoment() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "Lovely harbour \(UUID().uuidString)")
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)

        model.playSharedMarginMoment(row(fixture))
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertNil(model.lastError, "no failure line for a written Margin")
        XCTAssertNotNil(model.marginMoment, "the moment starts")
        XCTAssertEqual(model.screen, .playback)

        model.playMarginMomentNow()
        try await fixture.waitUntil("the reading plays and the Margin is marked heard") {
            model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first?.isNewToListener == false
        }
        XCTAssertNil(model.lastError)
    }

    // A note the voice cannot read says so with the reading's words, and no moment starts.
    func testTappingANoteTheVoiceCannotReadSaysSoAndStartsNoMoment() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.playSharedMarginMoment(row(fixture))
        XCTAssertEqual(model.lastError, "This Margin can't be read aloud on this iPhone.")
        XCTAssertNil(model.marginMoment)
    }

    // A voice Margin whose recording is gone is a recording problem; the line never says it was "read aloud" (finding 2).
    func testTappingAVoiceMarginWhoseRecordingIsGoneSaysTheRecordingCouldNotPlay() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try FileManager.default.removeItem(atPath: try XCTUnwrap(fixture.record.audioPath))

        model.playSharedMarginMoment(row(fixture))
        XCTAssertEqual(model.lastError, "That Margin's recording couldn't play.")
        XCTAssertNil(model.marginMoment)
    }
}
