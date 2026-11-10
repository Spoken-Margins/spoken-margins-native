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

    func testShowNameAppearsOnce() {
        XCTAssertTrue(PlaybackTitleMode.full.showsSeparateShowLine)
        XCTAssertFalse(PlaybackTitleMode.compact.showsSeparateShowLine)
    }
}
