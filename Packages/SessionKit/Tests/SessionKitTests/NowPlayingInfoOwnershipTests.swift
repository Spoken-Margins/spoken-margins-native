import XCTest
@testable import SessionKitAudio

/// #2181: three writers put the Lock Screen card up and took it down with no regard for each other, so a clear meant for
/// one writer's card removed another's and the Lock Screen lost its transport controls.
final class NowPlayingInfoOwnershipTests: XCTestCase {
    private final class FakeSink: NowPlayingInfoSink, @unchecked Sendable {
        private(set) var info: [String: Any]?
        private(set) var setCount = 0
        func setNowPlayingInfo(_ info: [String: Any]?) {
            self.info = info
            setCount += 1
        }
        var hasNowPlayingInfo: Bool { info != nil }
        var title: String? { info?["title"] as? String }
    }

    private func make() -> (NowPlayingInfoOwnership, FakeSink) {
        let sink = FakeSink()
        return (NowPlayingInfoOwnership(sink: sink, now: { Date(timeIntervalSince1970: 0) }), sink)
    }

    /// #2844: the owner's call (2026-11-06) is to keep the app's listening out of Journaling Suggestions, which can pass
    /// what is playing to other apps. Each writer's card must carry the flag, however it is written.
    func testEveryWritersCardIsExcludedFromSuggestions() {
        let key = NowPlayingInfoOwnership.excludeFromSuggestionsKey
        for writer in [NowPlayingWriter.mediaPlayer, .compactControls, .sharedMargin] {
            let (ledger, sink) = make()
            ledger.write(["title": "A"], as: writer)
            XCTAssertEqual(sink.info?[key] as? Bool, true, "write as \(writer)")
            XCTAssertEqual(sink.title, "A", "the card's own fields are untouched")
        }
        let (ledger, sink) = make()
        XCTAssertTrue(ledger.writeIfUnheld(["title": "B"], as: .compactControls))
        XCTAssertEqual(sink.info?[key] as? Bool, true, "writeIfUnheld")
        // A rewrite by the holder, which the player does every second, keeps the flag too.
        ledger.write(["title": "C"], as: .compactControls)
        XCTAssertEqual(sink.info?[key] as? Bool, true, "rewrite")
    }

    // MARK: Artwork (#3864)

    private let artworkKey = NowPlayingInfoOwnership.artworkKey
    private final class Picture: NSObject {}

    func testThePictureIsAddedToTheCardOfItsItemAndEveryOtherKeyStays() {
        let (ledger, sink) = make()
        let picture = Picture()
        ledger.setArtwork(picture, forItem: "a")
        ledger.write(["title": "A", "rate": 1.0], as: .mediaPlayer, itemId: "a")
        XCTAssertTrue(sink.info?[artworkKey] as? Picture === picture)
        XCTAssertEqual(sink.title, "A")
        XCTAssertEqual(sink.info?["rate"] as? Double, 1.0)
        XCTAssertEqual(sink.info?[NowPlayingInfoOwnership.excludeFromSuggestionsKey] as? Bool, true)
        // The player rewrites every second; the picture is merged into each write, so none drops it.
        ledger.write(["title": "A", "rate": 1.0, "elapsed": 5.0], as: .mediaPlayer, itemId: "a")
        XCTAssertTrue(sink.info?[artworkKey] as? Picture === picture)
        XCTAssertEqual(ledger.currentHolder, .mediaPlayer)
    }

    func testAPictureSetAfterTheCardIsUpRepublishesItWithoutChangingTheHolderOrTheOtherKeys() {
        let (ledger, sink) = make()
        ledger.write(["title": "A"], as: .compactControls, itemId: "a")
        XCTAssertNil(sink.info?[artworkKey], "nothing yet")
        let picture = Picture()
        ledger.setArtwork(picture, forItem: "a")
        XCTAssertTrue(sink.info?[artworkKey] as? Picture === picture)
        XCTAssertEqual(sink.title, "A")
        XCTAssertEqual(ledger.currentHolder, .compactControls, "one owner of the card, still")
        XCTAssertEqual(sink.info?[NowPlayingInfoOwnership.excludeFromSuggestionsKey] as? Bool, true)
    }

    func testAnItemChangeNeverShowsThePreviousItemsPicture() {
        let (ledger, sink) = make()
        let pictureA = Picture(), pictureB = Picture()
        ledger.setArtwork(pictureA, forItem: "a")
        ledger.write(["title": "A"], as: .mediaPlayer, itemId: "a")
        XCTAssertTrue(sink.info?[artworkKey] as? Picture === pictureA)

        // The queue moves on: the card is written for B before B's picture is ready.
        ledger.write(["title": "B"], as: .mediaPlayer, itemId: "b")
        XCTAssertNil(sink.info?[artworkKey], "A's picture is not B's")
        XCTAssertEqual(sink.title, "B")

        // A picture for B arrives and replaces the slot; later writes for B keep it, and A's is gone.
        ledger.setArtwork(pictureB, forItem: "b")
        XCTAssertTrue(sink.info?[artworkKey] as? Picture === pictureB)
        ledger.write(["title": "B"], as: .mediaPlayer, itemId: "b")
        XCTAssertTrue(sink.info?[artworkKey] as? Picture === pictureB)
        ledger.write(["title": "A again"], as: .mediaPlayer, itemId: "a")
        XCTAssertNil(sink.info?[artworkKey], "back on A, B's picture is not shown for it")
    }

    func testALatePictureForAnItemThatIsNoLongerPlayingDoesNotTouchTheCard() {
        let (ledger, sink) = make()
        ledger.write(["title": "B"], as: .mediaPlayer, itemId: "b")
        let setsBefore = sink.setCount
        ledger.setArtwork(Picture(), forItem: "a")
        XCTAssertEqual(sink.setCount, setsBefore, "the card for B is left alone")
        XCTAssertNil(sink.info?[artworkKey])
    }

    func testACardWithNoItemOrNoPictureIsAsBefore() {
        let (ledger, sink) = make()
        ledger.setArtwork(Picture(), forItem: "a")
        ledger.write(["title": "Shared Margin"], as: .sharedMargin)
        XCTAssertNil(sink.info?[artworkKey], "a card that names no item carries no picture")
        ledger.write(["title": "No art"], as: .mediaPlayer, itemId: "z")
        XCTAssertNil(sink.info?[artworkKey])
        XCTAssertEqual(sink.title, "No art")
    }

    func testRemovingThePictureAndClearingTheCard() {
        let (ledger, sink) = make()
        ledger.setArtwork(Picture(), forItem: "a")
        ledger.write(["title": "A"], as: .mediaPlayer, itemId: "a")
        ledger.setArtwork(nil, forItem: "a")
        XCTAssertNil(sink.info?[artworkKey])
        XCTAssertEqual(sink.title, "A")
        XCTAssertTrue(ledger.clear(as: .mediaPlayer))
        let setsAfterClear = sink.setCount
        ledger.setArtwork(Picture(), forItem: "a")
        XCTAssertNil(sink.info, "a picture set with no card up does not make one")
        XCTAssertEqual(sink.setCount, setsAfterClear)
    }

    func testAnotherWritersClearDoesNotLoseThePicture() {
        let (ledger, sink) = make()
        let picture = Picture()
        ledger.setArtwork(picture, forItem: "a")
        ledger.write(["title": "A"], as: .mediaPlayer, itemId: "a")
        XCTAssertFalse(ledger.clear(as: .compactControls))
        XCTAssertTrue(sink.info?[artworkKey] as? Picture === picture)
    }

    func testAClearFromAnotherWriterLeavesTheHoldersCard() {
        let (ledger, sink) = make()
        ledger.write(["title": "Substack post"], as: .mediaPlayer)

        // The compact-controls coordinator ends its own (stale) claim, as it does when a Margin's voice takes over or
        // the lifecycle republishes. It must not take the player's card down with it.
        XCTAssertFalse(ledger.clear(as: .compactControls, detail: "end"))

        XCTAssertEqual(sink.title, "Substack post")
        XCTAssertEqual(ledger.currentHolder, .mediaPlayer)
    }

    func testThePlayersClearOnEveryTickDoesNotRemoveALiveSpeechCard() {
        let (ledger, sink) = make()
        ledger.write(["title": "Narrated article"], as: .compactControls)

        // The media player, with its remote commands off, clears on each tick while speech plays.
        for _ in 0..<5 { XCTAssertFalse(ledger.clear(as: .mediaPlayer)) }

        XCTAssertEqual(sink.title, "Narrated article")
        XCTAssertEqual(ledger.currentHolder, .compactControls)
    }

    func testTheHoldersOwnClearRemovesTheCard() {
        let (ledger, sink) = make()
        ledger.write(["title": "A"], as: .mediaPlayer)

        XCTAssertTrue(ledger.clear(as: .mediaPlayer))

        XCTAssertNil(sink.info)
        XCTAssertNil(ledger.currentHolder)
    }

    func testALaterWriterTakesTheCardAndTheEarlierWritersClearIsThenIgnored() {
        let (ledger, sink) = make()
        ledger.write(["title": "Podcast"], as: .mediaPlayer)
        ledger.write(["title": "Shared Margin"], as: .sharedMargin)

        XCTAssertFalse(ledger.clear(as: .mediaPlayer))
        XCTAssertEqual(sink.title, "Shared Margin")

        XCTAssertTrue(ledger.clear(as: .sharedMargin))
        XCTAssertNil(sink.info)
    }

    func testAFillInWriterNeverOverwritesAHeldCard() {
        let (ledger, sink) = make()
        ledger.write(["title": "Player card"], as: .mediaPlayer)

        XCTAssertFalse(ledger.writeIfUnheld(["title": "Metadata only"], as: .compactControls))
        XCTAssertEqual(sink.title, "Player card")

        ledger.clear(as: .mediaPlayer)
        XCTAssertTrue(ledger.writeIfUnheld(["title": "Metadata only"], as: .compactControls))
        XCTAssertEqual(sink.title, "Metadata only")
        XCTAssertEqual(ledger.currentHolder, .compactControls)
    }

    func testAClearWithNoHolderTouchesNothing() {
        let (ledger, sink) = make()

        XCTAssertFalse(ledger.clear(as: .mediaPlayer))

        XCTAssertEqual(sink.setCount, 0)
    }

    func testDiagnosticsNameTheHolderAndListTheRefusedClearOnce() {
        let (ledger, _) = make()
        ledger.write(["title": "A"], as: .mediaPlayer, detail: "targets=7")
        for _ in 0..<50 { ledger.write(["title": "A"], as: .mediaPlayer) } // the 1 s player tick
        for _ in 0..<50 { ledger.clear(as: .compactControls, detail: "end") }
        ledger.note("lifecycle_refresh")

        let summary = ledger.summary()

        XCTAssertTrue(summary.hasPrefix("holder=media_player card=present rewrites=media_player×50"), summary)
        XCTAssertEqual(ledger.recentEvents().map(\.kind), [.write, .clearIgnored, .note], "ticks are counted, not listed")
        XCTAssertTrue(summary.contains("clear_ignored compact_controls held=media_player end"), summary)
        XCTAssertTrue(summary.contains("note held=media_player lifecycle_refresh card=present"), summary)
    }

    func testTheHistoryKeepsTheLatestTransitions() {
        let (ledger, _) = make()
        for index in 0..<30 {
            ledger.write(["title": "x"], as: index.isMultiple(of: 2) ? .mediaPlayer : .compactControls)
        }

        XCTAssertEqual(ledger.recentEvents().count, 12)
    }
}
