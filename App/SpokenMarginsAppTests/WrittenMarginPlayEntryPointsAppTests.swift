import AVFoundation
import SessionKit
import SessionKitAudio
import SwiftUI
import UIKit
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

    // A spot whose only Margin is a note the voice cannot read has nothing to play. The tap still takes that Margin, and
    // goes to its place with no voice (#4934), so the listener lands there and is not told it "can't be read": no moment starts.
    func testAHotSpotWhoseOnlyNoteCannotBeReadGoesToItsPlaceWithNoVoiceAndStartsNoMoment() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model

        let spot = try XCTUnwrap(hotSpots(fixture).first)
        let target = try XCTUnwrap(ReactionsPlayTarget.forHotSpot(spot, in: model.selectedItem))
        XCTAssertEqual(target.marginId, fixture.record.id, "with nothing playable the first Margin is taken, so the tap explains")

        model.seekMedia(toMediaTimeMs: 20_000)
        try await fixture.waitUntil("the source is playing near 20 s") {
            model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? 0) >= 19_900
        }
        target.play(in: model.selectedItem, on: model)
        defer { model.pause() }
        XCTAssertNil(model.lastError, "no failure line: the tap goes there")
        XCTAssertNil(model.marginMoment)
        XCTAssertEqual(model.silentMarginLanding?.marginId, fixture.record.id)
        try await fixture.waitUntil("the source is at the Margin's place and playing on") {
            model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? Int.max) < 5_000
        }
    }

    // A voice Margin is still picked as before: with an unreadable note ahead of it in the spot, the tap takes the recording.
    func testAHotSpotStillPicksAVoiceMarginWithARecordingOverAnEarlierNoteThatCannotPlay() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let unreadable = addFriend("Ana", words: "🎧", atMs: 500, to: fixture)

        let spot = try XCTUnwrap(hotSpots(fixture).first)
        XCTAssertEqual(spot.entries.map(\.marginId), [unreadable.id, fixture.record.id], "Ana's note is first in the spot")
        let target = try XCTUnwrap(ReactionsPlayTarget.forHotSpot(spot, in: model.selectedItem))
        XCTAssertEqual(target, ReactionsPlayTarget(layerId: fixture.layer.id, marginId: fixture.record.id), "the recording, not the first entry")
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

    // A note the voice cannot read has a disabled Play button in both lists, so no tap reaches the failure line there. Its
    // row has a Go-to button instead (#4934): the tap moves the source to the Margin's place, plays on, starts no moment and
    // reads nothing, and the pinned card on Now shows the words. Not marked heard: a voice downloaded later still has it to read (#3402).
    func testTheGoToButtonIsEnabledForANoteTheVoiceCannotReadAndItsTapMovesWithNoVoice() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        let unreadable = row(fixture)
        XCTAssertFalse(unreadable.canPlayFromNearbyList)
        XCTAssertFalse(unreadable.canPlayFromMarginsList)
        XCTAssertTrue(unreadable.goesToFromList, "the row's button goes to the Margin's place instead")

        model.seekMedia(toMediaTimeMs: 20_000) // the owner's #4447 position: well past the Margin
        try await fixture.waitUntil("the source is playing near 20 s") {
            model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? 0) >= 19_900
        }
        model.goToSharedMargin(unreadable)
        defer { model.pause() }

        XCTAssertNil(model.lastError, "a go-to has no failure line")
        XCTAssertNil(model.marginMoment, "no lead-in, no voice")
        XCTAssertNil(model.pendingImportedCommentary)
        XCTAssertNil(model.playingImportedCommentary)
        XCTAssertEqual(model.screen, .playback)
        try await fixture.waitUntil("the source is at the Margin's place and playing on") {
            model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? Int.max) < 5_000
        }
        let card = try XCTUnwrap(model.pinnedMarginCard, "the card on Now")
        XCTAssertEqual(card.stage, .silentHere(words: "🎧", isApproximate: false))
        XCTAssertEqual(card.headline, "Margin from Reviewer is here")
        XCTAssertNil(model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first?.firstHeardAt,
                     "a note with no voice on this phone is not marked heard")

        model.dismissSilentMarginLanding()
        XCTAssertNil(model.shownSilentMarginLanding, "Dismiss hides the card")
        XCTAssertEqual(model.snapshot.status, .playing, "and the source keeps playing")
    }

    // A friend's note nobody will read aloud is a place to go whoever turned reading off, and from a paused source as from a
    // playing one: the sender's choice marks it heard on landing (the details sheet's own rule, #3427); the listener's turn-off
    // already did when it was made. No path starts a moment or a voice.
    func testAGoToLandsOnANoteReadingWasTurnedOffForFromPlayingAndFromPaused() async throws {
        for senderOff in [true, false] {
            for startsPaused in [false, true] {
                let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords(), senderReadAloud: senderOff ? false : nil)
                defer { fixture.cleanUp() }
                let model = fixture.model
                if !senderOff { model.setSharedMarginReadAloud(fixture.record, readAloud: false) }
                let silent = row(fixture)
                let chosen = try XCTUnwrap(model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first)
                XCTAssertFalse(SharedMarginAudio.canOffer(chosen), "senderOff \(senderOff): never read aloud")
                let goingTo = SharedMarginRow(interjection: chosen, layer: silent.layer, itemTitle: silent.itemTitle)
                XCTAssertTrue(goingTo.goesToFromList)
                model.seekMedia(toMediaTimeMs: 20_000)
                try await fixture.waitUntil("the source is at 20 s") { (model.snapshot.currentMediaTimeMs ?? 0) >= 19_900 }
                if startsPaused {
                    model.pause()
                    try await fixture.waitUntil("the source is paused") { model.snapshot.status == .paused }
                }

                model.goToSharedMargin(goingTo)
                defer { model.pause() }
                let label = "senderOff \(senderOff), paused \(startsPaused)"
                XCTAssertNil(model.lastError, label)
                XCTAssertNil(model.marginMoment, label)
                XCTAssertNil(model.playingImportedCommentary, label)
                try await fixture.waitUntil("\(label): playing at the Margin's place") {
                    model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? Int.max) < 5_000
                }
                XCTAssertEqual(model.pinnedMarginCard?.stage, .silentHere(words: chosen.approvedTranscript, isApproximate: false), label)
                try await fixture.waitUntil("\(label): marked heard") {
                    model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first?.firstHeardAt != nil
                }
            }
        }
    }

    // The ways a go-to cannot start say so and move nothing: a source not in the Library, and a Margin with no place.
    func testAGoToWithNothingToGoToSaysSoAndMovesNothing() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        var elsewhere = fixture.layer
        elsewhere.itemId = nil
        model.goToSharedMargin(SharedMarginRow(interjection: fixture.record, layer: elsewhere, itemTitle: "Missing"))
        XCTAssertEqual(model.lastError, "The source for this shared Margin isn't in your Library.")
        XCTAssertNil(model.silentMarginLanding)

        let unplaced = ImportedCommentaryInterjection(
            id: "unplaced", layerId: fixture.layer.id, packageScopedId: "unplaced", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "🎧",
            resolution: ImportedAnchorResolution(evidenceClass: .unresolved))
        model.goToSharedMargin(SharedMarginRow(interjection: unplaced, layer: fixture.layer, itemTitle: "Real source"))
        XCTAssertEqual(model.lastError, "This shared Margin has no position in the episode.")
        XCTAssertNil(model.silentMarginLanding)
        XCTAssertNil(model.marginMoment)
    }

    // The Library's tap on a friend's silent Margin while another item plays (#4934): the other item gives way and this one
    // opens at the Margin's place, playing on with no voice, as `playSharedMarginMoment` opens the item first.
    func testAGoToFromTheLibraryWhileAnotherItemPlaysOpensThisItemAtThePlace() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        let silent = row(fixture)
        model.startItem(id: "item-pill")
        XCTAssertEqual(model.snapshot.itemId, "item-pill", "another item is open")

        model.goToSharedMargin(silent)
        defer { model.pause() }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.snapshot.itemId, fixture.layer.itemId, "the Margin's own item is open now")
        XCTAssertNil(model.marginMoment)
        XCTAssertEqual(model.silentMarginLanding?.itemId, fixture.layer.itemId)
        try await fixture.waitUntil("the source is at the Margin's place and playing") {
            model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? Int.max) < 5_000
        }
    }

    // MARK: A reply's parent, and a note with no voice on this phone (#3402)

    private func parentContext(_ fixture: ReturnFixture) -> MarginThreadPresentation.ParentContext {
        fixture.model.sharedMarginRows = [row(fixture)]
        return MarginThreadPresentation.ParentContext(parent: .imported(fixture.record.id), senderLabel: "Reviewer", text: fixture.record.approvedTranscript)
    }

    // "Hear what it answers" on a reply whose parent is a friend's written Margin plays the parent's reading.
    func testHearingAReplysWrittenParentPlaysItsReading() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)

        model.playMarginParent(parentContext(fixture))
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertNil(model.lastError)
        XCTAssertNotNil(model.marginMoment)
        try await waitUntilHeard(fixture)
    }

    // A parent nothing can read gets the plain line, as every other row does, and no moment starts.
    func testHearingAReplysParentThatCannotBeReadSaysSo() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.playMarginParent(parentContext(fixture))
        XCTAssertEqual(model.lastError, "This Margin can't be read aloud on this iPhone.")
        XCTAssertNil(model.marginMoment)
    }

    // That line has to be on the friend's sheet the button is on. The root's banner is behind the sheet, so with only that
    // the tap looked dead. Only the sheet is mounted here, so the banner found is the sheet's own.
    func testTheLineAboutAParentThatCannotBeReadIsShownOnTheFriendsSheet() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        let automationWasEnabled = AccessibilityAutomation.enable()
        defer { if let automationWasEnabled { AccessibilityAutomation.set(automationWasEnabled) } }
        let context = parentContext(fixture)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: AnyView(SharedMarginDetailView(row: row(fixture)).environmentObject(model)))
        window.makeKeyAndVisible()
        let mounted = MountedTree(window: window, previousKeyWindow: previousKeyWindow)
        defer { mounted.close() }
        _ = try await mounted.waitForNode("the sheet") { $0.label == "Hide this Margin" || $0.label == "Read this aloud" }

        model.playMarginParent(context)
        let line = "This Margin can't be read aloud on this iPhone."
        let banner = try await mounted.waitForNode("the banner on the sheet") { $0.identifier == "app.feedback.banner" }
        XCTAssertEqual(banner.label?.contains(line), true, "the banner said \(banner.label ?? "nothing")")
    }

    // No voice on this phone can read the note: nothing offers it and nothing calls it new, every row that plays one says
    // the plain line, and no heard fact is made. A voice arriving later brings it back: it reads as new and is offered.
    func testANoteWithNoVoiceHereIsNotNewNotOfferedAndComesBackWithAVoice() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp(); WrittenMarginSpeech.useVoiceCheck(nil) }
        let model = fixture.model
        let itemId = try XCTUnwrap(fixture.layer.itemId)
        XCTAssertEqual(model.newSharedMargins(itemId: itemId).count, 1)

        WrittenMarginSpeech.useVoiceCheck { _ in false }
        let silent = row(fixture)
        XCTAssertFalse(silent.isNew, "a Margin the listener has no way to meet doesn't wait as new")
        XCTAssertEqual(model.newSharedMargins(itemId: itemId).count, 0, "the offer and the item's screen")
        XCTAssertFalse(silent.canPlayFromNearbyList)
        XCTAssertFalse(silent.canPlayFromMarginsList)
        XCTAssertTrue(silent.goesToFromList, "it is still somewhere to go, with no voice (#4934)")

        model.playSharedMarginMoment(silent) // the voice-only path still says why
        XCTAssertEqual(model.lastError, "This Margin can't be read aloud on this iPhone.")
        XCTAssertNil(model.marginMoment)
        XCTAssertTrue(fixture.record.isNewToListener, "not new is not heard: firstHeardAt stays empty")
        XCTAssertNil(model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first?.firstHeardAt)

        WrittenMarginSpeech.useVoiceCheck { _ in true }
        XCTAssertTrue(row(fixture).isNew)
        XCTAssertEqual(model.newSharedMargins(itemId: itemId).count, 1)
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
