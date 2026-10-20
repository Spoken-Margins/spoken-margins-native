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
