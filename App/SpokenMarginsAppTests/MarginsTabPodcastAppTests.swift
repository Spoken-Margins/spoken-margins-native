import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest
@testable import SpokenMarginsApp

/// #4447: the owner's playback screen on a podcast with a friend's Margins, where "the skim controls" and "seeking to a
/// Margin from the Margins tab" did not work, and nothing in his export said which tap. These press what the Margins tab
/// and the chapter row press, on the real model with a real source player (the way `WrittenMarginSkimAppTests` and
/// `MarginMomentTapTests` do): a tap on a friend's row from far past the Margin, a tap on one of your own, and each
/// Skim arrow with both ahead. A red here, with its message, is the bug; a pass means these taps work on a media item,
/// which narrows #4447 to what only a phone shows. The sound of any of it is the owner's pass.
@MainActor
final class MarginsTabPodcastAppTests: XCTestCase {
    override func tearDown() async throws {
        await ReturnFixture.expectSharedReaderIdle()
        try await super.tearDown()
    }

    private func skimOutcomes(_ model: Gate1AppModel) -> [String] {
        model.playbackEventRecording.events.filter { $0.kind == "skim.press" }.compactMap { $0.fields["outcome"] }
    }

    private func friendRow(_ fixture: ReturnFixture) -> SharedMarginRow {
        SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")
    }

    /// The source playing well past the friend's Margin (at 1 s of the fixture's 30 s source).
    private func playFarPastTheMargin(_ fixture: ReturnFixture) async throws {
        fixture.model.seekMedia(toMediaTimeMs: 20_000)
        try await fixture.waitUntil("the source is playing near 20 s") {
            fixture.model.snapshot.status == .playing && (fixture.model.snapshot.currentMediaTimeMs ?? 0) >= 19_000
        }
    }

    // The Margins tab's Play on a friend's row, with the playhead far past the Margin: it goes back to the Margin and
    // plays it, and says nothing is wrong. (The row's closure is `playSharedMarginFromMarginsList`.)
    func testTheFriendsRowPlaysItsMomentFromFarPastIt() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let row = friendRow(fixture)
        model.sharedMarginRows = [row]
        try await playFarPastTheMargin(fixture)
        XCTAssertTrue(row.canPlayFromMarginsList, "the row's Play is enabled")

        model.playSharedMarginFromMarginsList(row)
        defer { model.endMarginMoment(); model.pause() }

        XCTAssertNil(model.lastError, "the tap says nothing is wrong")
        XCTAssertNotNil(model.marginMoment, "the Margin's moment started")
        XCTAssertEqual(model.screen, .playback)
        try await fixture.waitUntil("the source went back to the Margin's lead-in") {
            (model.snapshot.currentMediaTimeMs ?? Int.max) < 5_000
        }
    }

    // The Margins tab's Go-to on a friend's silent row (#4934), from the owner's #4447 position: far past the Margin. The row
    // is enabled as a Go-to and not as Play; the tap lands at the Margin's own place, plays on and starts no moment.
    func testTheSilentFriendsRowGoesToItsPlaceFromFarPastItAndPlaysOn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "Look at this part.", senderReadAloud: false)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let row = friendRow(fixture)
        model.sharedMarginRows = [row]
        try await playFarPastTheMargin(fixture)
        XCTAssertFalse(row.canPlayFromMarginsList, "nothing to play")
        XCTAssertTrue(row.goesToFromList, "the row's button goes there")

        model.goToSharedMargin(row)
        defer { model.pause() }

        XCTAssertNil(model.lastError)
        XCTAssertNil(model.marginMoment, "no lead-in and no voice")
        XCTAssertEqual(model.screen, .playback)
        try await fixture.waitUntil("the source is at the Margin's own place and playing on") {
            model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? Int.max) < 5_000
        }
        XCTAssertEqual(model.pinnedMarginCard?.stage, .silentHere(words: "Look at this part.", isApproximate: false))
    }

    // The same tap while the source is paused far past the Margin: a paused source goes back too, and plays.
    func testTheFriendsRowPlaysItsMomentFromAPausedSourceFarPastIt() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let row = friendRow(fixture)
        model.sharedMarginRows = [row]
        try await playFarPastTheMargin(fixture)
        model.pause()
        try await fixture.waitUntil("the source is paused") { model.snapshot.status != .playing }

        model.playSharedMarginFromMarginsList(row)
        defer { model.endMarginMoment(); model.pause() }

        XCTAssertNil(model.lastError)
        XCTAssertNotNil(model.marginMoment, "the Margin's moment started from a paused source")
        try await fixture.waitUntil("the source went back to the Margin's lead-in") {
            (model.snapshot.currentMediaTimeMs ?? Int.max) < 5_000
        }
    }

    // The Margins tab's Play on one of your own rows (`MarginMomentTap.start`), with the playhead before it and after it.
    func testYourOwnRowPlaysItsMomentFromBeforeAndFromAfterIt() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let own = try fixture.addOwnMargin(id: "own-tab-margin", atMediaTimeMs: 10_000, voiceSeconds: 2)
        model.refreshMarginRows()
        let row = MarginRow(interjection: own, itemTitle: "Real source", sessionDate: nil)
        defer { model.endMarginMoment(); model.pause() }

        for startingAt in [100, 25_000] {
            model.endMarginMoment()
            model.seekMedia(toMediaTimeMs: startingAt)
            try await fixture.waitUntil("the source is at \(startingAt) ms") {
                let at = model.snapshot.currentMediaTimeMs ?? Int.max
                return abs(at - startingAt) < 1_500
            }
            MarginMomentTap.start(row, model: model)
            await model.settleItemOpen()
            XCTAssertNil(model.lastError, "from \(startingAt) ms: the tap says nothing is wrong")
            XCTAssertNotNil(model.marginMoment, "from \(startingAt) ms: your own Margin's moment started")
        }
    }

    // The chapter row's two Skim arrows with the friend's Margin and one of your own both ahead, with the source paused:
    // the arrows are there, the forward one goes to the friend's Margin, the next press moves on, and nothing fails.
    func testSkimArrowsWithAFriendsAndYourOwnMarginAhead() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        _ = try fixture.addOwnMargin(id: "own-skim-margin", atMediaTimeMs: 10_000, voiceSeconds: 2)
        model.refreshMarginRows()
        model.sharedMarginRows = [friendRow(fixture)]
        model.pause()
        model.seekMedia(toMediaTimeMs: 100)
        try await fixture.waitUntil("the source is paused before both Margins") {
            model.snapshot.status != .playing && (model.snapshot.currentMediaTimeMs ?? Int.max) < 900
        }
        model.refreshSkimAvailabilityForTesting()
        defer { model.endMarginMoment(); model.pause() }

        XCTAssertTrue(model.snapshot.canSkimForward, "the forward arrow is offered with Margins ahead")
        XCTAssertTrue(model.showsSkimRow, "the chapter row draws its arrows")

        model.skimForward()
        XCTAssertEqual(skimOutcomes(model).last, "started_margin_lead_in", "the first press goes to the friend's Margin")
        XCTAssertNil(model.lastError)
        XCTAssertNotNil(model.marginMoment)
        try await fixture.waitUntil("the friend's voice is sounding") { model.marginMomentConductor?.isPlayingVoice == true }

        model.skimForward()
        XCTAssertEqual(skimOutcomes(model).last, "skipped_margin_voice", "the press during the voice skips it")
        try await fixture.waitUntil("the episode plays on") {
            model.marginMomentConductor?.isPlayingVoice != true && model.snapshot.status == .playing
        }

        model.skimForward()
        XCTAssertEqual(skimOutcomes(model).count, 3, "the third press was recorded: \(skimOutcomes(model))")
        XCTAssertNil(model.lastError, "the press after the first Margin says nothing is wrong: \(skimOutcomes(model))")

        model.skimBackward()
        XCTAssertEqual(skimOutcomes(model).count, 4, "the backward press was recorded: \(skimOutcomes(model))")
        XCTAssertNil(model.lastError, "the backward press says nothing is wrong: \(skimOutcomes(model))")
    }
}
