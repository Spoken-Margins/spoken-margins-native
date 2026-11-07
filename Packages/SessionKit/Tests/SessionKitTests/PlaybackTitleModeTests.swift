import XCTest
@testable import SessionKit

final class PlaybackTitleModeTests: XCTestCase {
    func testModeFollowsSlotNotStage() {
        // slot held: card playing, waiting on a tap, counting down between Margins, heard-and-listening
        XCTAssertEqual(PlaybackTitleMode.choose(cardSlotHeld: true), .compact)
        // no card, and the friend listen ended
        XCTAssertEqual(PlaybackTitleMode.choose(cardSlotHeld: false), .full)
    }

    func testCompactLinePrefersSourceName() {
        XCTAssertEqual(PlaybackTitleMode.compactLine(title: "Episode 12: A very long title", sourceName: "The Show"), "The Show")
        XCTAssertEqual(PlaybackTitleMode.compactLine(title: "An article", sourceName: nil), "An article")
        XCTAssertEqual(PlaybackTitleMode.compactLine(title: "An article", sourceName: "  \n"), "An article")
        XCTAssertEqual(PlaybackTitleMode.compactLine(title: "", sourceName: ""), "")
    }

    func testHintUsesListenersWord() {
        XCTAssertEqual(PlaybackTitleMode.detailsHint(noun: .episode), "Opens details and listening history for this episode")
        XCTAssertEqual(PlaybackTitleMode.detailsHint(noun: .pdf), "Opens details and listening history for this PDF")
        XCTAssertEqual(PlaybackTitleMode.detailsHint(noun: nil), "Opens details and listening history for this source")
        XCTAssertFalse(PlaybackTitleMode.detailsHint(noun: .article).lowercased().contains("item"))
    }
}
