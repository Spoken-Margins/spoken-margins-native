import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest
@testable import SpokenMarginsApp

/// #3425, from the sibling check on #3412: three more places decide whether a friend's written Margin can be played, and
/// none had a test of its own. A hot spot in "Where people reacted" picks the Margin its tap plays; the Play button on a
/// shared-Margin row in the Now tab's "Nearby Margins" and in the Margins tab is enabled or not. Each test here uses the
/// function the screen uses (`ReactionsPlayTarget`, `SharedMarginRow.canPlayFrom…`) and then the call the tap makes
/// (`playSharedMarginMoment`), with a real source player and a real file where the reading would be rendered, and proves
/// either that the reading plays or that the plain failure line appears.
@MainActor
final class WrittenMarginPlayEntryPointsAppTests: XCTestCase {
    private func row(_ fixture: ReturnFixture) -> SharedMarginRow {
        SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")
    }

    private func uniqueWords() -> String { "Lovely harbour \(UUID().uuidString)" }

    /// A second friend with a note at `timeMs` in the same source, added to the open item the way the fixture adds its own.
    private func addFriend(_ label: String, words: String, atMs timeMs: Int, to fixture: ReturnFixture) -> ImportedCommentaryInterjection {
        let layer = ImportedCommentaryLayer(id: "layer-\(label)", itemId: fixture.layer.itemId, packageDigest: "digest-\(label)",
            packageId: "package-\(label)", itemIdentity: SharedItemIdentity(itemType: .other, title: "Source"),
            displayLabel: label, importedAt: Date(), sourceResolutionStatus: .resolved, isEnabled: true, isMuted: true, revealMode: .companion)
        let note = ImportedCommentaryInterjection(id: "note-\(label)", layerId: layer.id, packageScopedId: "note-\(label)", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: words,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: timeMs, confidence: 1))
        fixture.model.selectedItem.importedCommentaryLayers.append(layer)
        fixture.model.selectedItem.importedCommentaryInterjections[layer.id] = [note]
        return note
    }

    private func hotSpots(_ fixture: ReturnFixture, unchecking unchecked: Set<String> = []) -> [MarginLayerSynthesis.HotSpot] {
        var selection = ReactionsSelection()
        selection.unchecked = unchecked
        return MarginLayerSynthesis.hotSpots(selection.input(for: fixture.model.selectedItem, ownMargins: []))
    }

    private func waitUntilHeard(_ fixture: ReturnFixture) async throws {
        let model = fixture.model
        model.playMarginMomentNow()
        try await fixture.waitUntil("the reading plays and the Margin is marked heard") {
            model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first?.isNewToListener == false
        }
    }

    // MARK: A hot spot in "Where people reacted"

    // Ana's note comes first in the spot, and the voice cannot read it (only an emoji). The tap must skip it and play
    // Reviewer's written Margin, whose reading is on disk: before #3412 a written Margin was never "playable" here, so the
    // tap took the first entry whatever it was.
    func testAHotSpotPicksAWrittenMarginWithAReadingOverAnEarlierNoteThatCannotPlay() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)
        let unreadable = addFriend("Ana", words: "🎧", atMs: 500, to: fixture)

        let spots = hotSpots(fixture)
        XCTAssertEqual(spots.count, 1, "the two notes are one hot spot")
        XCTAssertEqual(spots.first?.entries.map(\.marginId), [unreadable.id, fixture.record.id], "Ana's note is first in the spot")
        let item = model.selectedItem
        let target = try XCTUnwrap(ReactionsPlayTarget.forHotSpot(try XCTUnwrap(spots.first), in: item))
        XCTAssertEqual(target, ReactionsPlayTarget(layerId: fixture.layer.id, marginId: fixture.record.id), "the written Margin is the one to play")

        target.play(in: item, on: model)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertNil(model.lastError, "no failure line: the reading plays")
        XCTAssertNotNil(model.marginMoment, "the moment starts")
        try await waitUntilHeard(fixture)
        XCTAssertNil(model.lastError)
    }

    // A written Margin alone in its spot is the one to play, and it plays.
    func testAHotSpotWithOnlyAWrittenMarginPlaysItsReading() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)

        let spot = try XCTUnwrap(hotSpots(fixture).first)
        let target = try XCTUnwrap(ReactionsPlayTarget.forHotSpot(spot, in: model.selectedItem))
        XCTAssertEqual(target.marginId, fixture.record.id)

        target.play(in: model.selectedItem, on: model)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertNil(model.lastError)
        XCTAssertNotNil(model.marginMoment)
        try await waitUntilHeard(fixture)
    }

    // A spot whose only Margin is a note the voice cannot read has nothing to play. The tap still takes that Margin, so
    // the listener gets the plain line and not silence, and no moment starts.
    func testAHotSpotWhoseOnlyNoteCannotBeReadSaysSoAndStartsNoMoment() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model

        let spot = try XCTUnwrap(hotSpots(fixture).first)
        let target = try XCTUnwrap(ReactionsPlayTarget.forHotSpot(spot, in: model.selectedItem))
        XCTAssertEqual(target.marginId, fixture.record.id, "with nothing playable the first Margin is taken, so the tap explains")

        target.play(in: model.selectedItem, on: model)
        XCTAssertEqual(model.lastError, "This Margin can't be read aloud on this iPhone.")
        XCTAssertNil(model.marginMoment)
    }

    // A voice Margin is still picked as before, ahead of a written one that comes later in the spot.
    func testAHotSpotStillPicksAVoiceMarginWithARecording() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        _ = addFriend("Zed", words: uniqueWords(), atMs: 1_500, to: fixture)

        let spot = try XCTUnwrap(hotSpots(fixture).first)
        XCTAssertEqual(spot.entries.count, 2)
        let target = try XCTUnwrap(ReactionsPlayTarget.forHotSpot(spot, in: model.selectedItem))
        XCTAssertEqual(target, ReactionsPlayTarget(layerId: fixture.layer.id, marginId: fixture.record.id), "the first Margin that can play, the recording")
    }

    // MARK: The Play button on a shared-Margin row

    // The Now tab's "Nearby Margins" row and the Margins tab's row both enable Play for a written Margin; the tap is
    // `playSharedMarginMoment(row)`. With the reading on disk it plays and the Margin is marked heard.
    func testThePlayButtonIsEnabledForAWrittenMarginInBothListsAndItsTapPlaysTheReading() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)
        let written = row(fixture)
        XCTAssertTrue(written.canPlayFromNearbyList, "Now tab: Play is enabled for a written Margin")
        XCTAssertTrue(written.canPlayFromMarginsList, "Margins tab: Play is enabled for a placed written Margin")

        model.playSharedMarginMoment(written)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertNil(model.lastError, "no failure line for a written Margin")
        XCTAssertNotNil(model.marginMoment)
        XCTAssertEqual(model.screen, .playback)
        try await waitUntilHeard(fixture)
        XCTAssertNil(model.lastError)
    }

    // A note the voice cannot read has a disabled Play button in both lists, so no tap reaches the failure line there.
    // The same Margin reached by another path (the Timeline) says why in plain words, which the Timeline tests cover.
    func testThePlayButtonIsDisabledForANoteTheVoiceCannotRead() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let unreadable = row(fixture)
        XCTAssertFalse(unreadable.canPlayFromNearbyList)
        XCTAssertFalse(unreadable.canPlayFromMarginsList)
    }

    // A voice Margin keeps its enabled Play button in both lists, and a tap plays its recording through the moment.
    func testThePlayButtonStaysEnabledForAVoiceMargin() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let voice = row(fixture)
        XCTAssertTrue(voice.canPlayFromNearbyList)
        XCTAssertTrue(voice.canPlayFromMarginsList)

        model.playSharedMarginMoment(voice)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertNil(model.lastError)
        XCTAssertNotNil(model.marginMoment)
    }
}
