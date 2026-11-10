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

    func testVoiceControlAnswersToTheDrawnWords() {
        // compact: the drawn line first, then the full title the label carries
        XCTAssertEqual(PlaybackTitleMode.compact.voiceControlNames(title: "Episode 12: A very long title", sourceName: "The Show"),
                       ["The Show", "Episode 12: A very long title"])
        // every drawn line is a Voice Control name
        for sourceName in ["The Show", "  Publisher ", nil, "", "Episode 12"] as [String?] {
            let title = "Episode 12"
            let drawn = PlaybackTitleMode.compactLine(title: title, sourceName: sourceName)
            let names = PlaybackTitleMode.compact.voiceControlNames(title: title, sourceName: sourceName)
            XCTAssertTrue(names.contains(drawn), "\(drawn) missing from \(names)")
            XCTAssertTrue(names.contains(title))
            XCTAssertEqual(names.count, Set(names).count, "no duplicates")
        }
        // full: the title is both drawn and the label
        XCTAssertEqual(PlaybackTitleMode.full.voiceControlNames(title: "An article", sourceName: "The Show"), ["An article"])
        // nothing empty
        XCTAssertEqual(PlaybackTitleMode.compact.voiceControlNames(title: "", sourceName: nil), [])
    }
}
