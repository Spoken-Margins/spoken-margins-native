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
    private func row(_ fixture: ReturnFixture) -> SharedMarginRow {
        SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")
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
