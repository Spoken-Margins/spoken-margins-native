import XCTest
@testable import SessionKit

final class PlaybackMarginPreviewTests: XCTestCase {
    func testEmptyTranscriptAlwaysSaysTranscriptPending() {
        for empty: String? in [nil, "", " \n\t", "\u{00a0}"] {
            XCTAssertEqual(PlaybackMarginPreview.text(displayText: empty, cleanedTranscript: empty, transcript: empty), "Transcript pending")
        }
    }

    func testPreviewKeepsReviewedThenCleanedThenRawWords() {
        XCTAssertEqual(PlaybackMarginPreview.text(displayText: "  Reviewed words\n", cleanedTranscript: "Cleaned words", transcript: "Raw words"), "Reviewed words")
        XCTAssertEqual(PlaybackMarginPreview.text(displayText: " \n", cleanedTranscript: " Cleaned words ", transcript: "Raw words"), "Cleaned words")
        XCTAssertEqual(PlaybackMarginPreview.text(displayText: nil, cleanedTranscript: "\t", transcript: " Raw words "), "Raw words")
    }

    func testPreviewDoesNotRewriteOrClassifyTheListenersWords() {
        for words in ["Audio saved. Transcript failed.", "Case Matters", "Cafe\u{0301} ☕", "Two\nparagraphs", String(repeating: "A", count: 4_000)] {
            XCTAssertEqual(PlaybackMarginPreview.text(displayText: words, cleanedTranscript: nil, transcript: nil), words)
        }
    }
}
