import XCTest
import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

/// #3638: a tap's open that is still reading must be dropped when the listener started playback meanwhile, whichever
/// way they started it. Playing a shared Margin, starting an item, Skim and the transport never touched the open gate;
/// `openItemFromTap` now asks what is playing (`PlaybackStartMark`) instead. Every test taps from the playback screen,
/// which a start keeps, so the late open's own "the listener left that screen" check can't be what drops it.
@MainActor
final class PendingOpenPlaybackStartTests: XCTestCase {
    private var priorTermsVersion: Any?
    private var priorTermsDate: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDown() async throws {
        for (value, key) in [(priorTermsVersion, SpokenMarginsTerms.acceptanceVersionKey), (priorTermsDate, SpokenMarginsTerms.acceptanceDateKey)] {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await super.tearDown()
    }

    /// Two text items; the first is playing and the model is on the playback screen.
    private func playingFirstItem() -> (model: Gate1AppModel, first: String, second: String) {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "First Item"
        model.importText = "One sentence only."
        model.importTextItem()
        let first = model.selectedItem.id
        model.importTitle = "Second Item"
        model.importText = "Another sentence only."
        model.importTextItem()
        let second = model.selectedItem.id
        model.startItem(id: first)
        return (model, first, second)
    }

    func testStartingAnItemBeforeTheOpenIsReadDropsTheOpen() async throws {
        let (model, first, second) = playingFirstItem()
        defer { model.pause() }
        XCTAssertEqual(model.screen, .playback, "the tap comes from the playback screen, which a new item keeps")
        model.openItemFromTap(id: first)
        model.startItem(id: second) // starting an item does not touch the open gate
        XCTAssertEqual(model.screen, .playback)
        await model.settleItemOpen()
        XCTAssertEqual(model.screen, .playback, "a late open must not cover the playback the listener just started")
        XCTAssertEqual(model.snapshot.itemId, second)
        XCTAssertEqual(model.activeItemId, second)
    }

    func testPlayingFromTheTransportBeforeTheOpenIsReadDropsTheOpen() async throws {
        let (model, first, second) = playingFirstItem()
        defer { model.pause() }
        model.pause()
        XCTAssertFalse(model.snapshot.status.isPlaybackActive, "paused when the tap is made")
        XCTAssertEqual(model.screen, .playback)
        model.openItemFromTap(id: second)
        model.dispatchGate2CompactCommand(.play)
        XCTAssertTrue(model.snapshot.status.isPlaybackActive, "the transport started playback")
        await model.settleItemOpen()
        XCTAssertEqual(model.screen, .playback, "a late open must not pull the listener off the playback they resumed")
        XCTAssertEqual(model.snapshot.itemId, first)
        XCTAssertNotEqual(model.activeItemId, second)
    }

    func testPlayingASharedMarginMomentBeforeTheOpenIsReadDropsTheOpen() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        defer { model.endMarginMoment(); model.pause() }
        let row = SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")
        XCTAssertEqual(model.screen, .playback)
        model.openItemFromTap(id: "real-source")
        model.playSharedMarginMoment(row) // the source is already playing: only the Margin's moment changes
        XCTAssertNotNil(model.marginMoment, "the moment started")
        await model.settleItemOpen()
        XCTAssertEqual(model.screen, .playback, "a late open must not cover the Margin's moment")
        await ReturnFixture.expectSharedReaderIdle()
    }

    /// The other side of the rule: playback going on, or ending, with nothing started, leaves the open alone.
    func testAnOpenStillLandsWhenNothingWasStartedMeanwhile() async throws {
        let (model, _, second) = playingFirstItem()
        defer { model.pause() }
        model.openItemFromTap(id: second)
        await model.settleItemOpen()
        XCTAssertEqual(model.screen, .item, "a tap with nothing else started still opens, over playing audio too")
        XCTAssertEqual(model.selectedItem.id, second)
    }

    func testAPauseBeforeTheOpenIsReadDoesNotDropTheOpen() async throws {
        let (model, _, second) = playingFirstItem()
        defer { model.pause() }
        model.openItemFromTap(id: second)
        model.pause()
        await model.settleItemOpen()
        XCTAssertEqual(model.screen, .item, "a pause starts nothing")
        XCTAssertEqual(model.selectedItem.id, second)
    }
}
