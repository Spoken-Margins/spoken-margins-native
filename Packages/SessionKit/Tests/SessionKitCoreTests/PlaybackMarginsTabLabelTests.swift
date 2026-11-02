import XCTest
@testable import SessionKit

final class PlaybackMarginsTabLabelTests: XCTestCase {
    func testNothingReceivedLeavesTheTabPlain() {
        for count in [0, -1] {
            XCTAssertEqual(PlaybackMarginsTabLabel.title(receivedCount: count), "Margins")
            XCTAssertEqual(PlaybackMarginsTabLabel.accessibilityLabel(receivedCount: count), "Margins")
        }
    }

    func testReceivedMarginsAreCountedInWords() {
        XCTAssertEqual(PlaybackMarginsTabLabel.title(receivedCount: 1), "Margins 1")
        XCTAssertEqual(PlaybackMarginsTabLabel.title(receivedCount: 7), "Margins 7")
        XCTAssertEqual(PlaybackMarginsTabLabel.accessibilityLabel(receivedCount: 1), "Margins, 1 received")
        XCTAssertEqual(PlaybackMarginsTabLabel.accessibilityLabel(receivedCount: 7), "Margins, 7 received")
    }

    func testLargeCountsStopAtTheCapSoTheTabKeepsItsWidth() {
        XCTAssertEqual(PlaybackMarginsTabLabel.title(receivedCount: 99), "Margins 99")
        XCTAssertEqual(PlaybackMarginsTabLabel.title(receivedCount: 100), "Margins 99+")
        XCTAssertEqual(PlaybackMarginsTabLabel.title(receivedCount: 4_000), "Margins 99+")
        // VoiceOver is not width-bound, so it reads the real number.
        XCTAssertEqual(PlaybackMarginsTabLabel.accessibilityLabel(receivedCount: 4_000), "Margins, 4000 received")
    }
}
