import XCTest
@testable import SessionKit

final class PlaybackMarginPreviewTests: XCTestCase {
    func testEmptyTranscriptUsesOnlyARealPendingStateAsPending() {
        let states = ["pending", "failed", "transcribed", "complete", "", "unknown", "transcribing"]
        let kinds: [InterjectionCaptureKind?] = [.audio, .written, nil]
        for kind in kinds {
            for status in states {
                for empty: String? in [nil, "", " \n\t", "\u{00a0}"] {
                    let expected = kind == .written ? "Written Margin"
                        : status == "pending" ? "Transcript pending" : "Audio Margin"
                    XCTAssertEqual(PlaybackMarginPreview.text(displayText: empty, cleanedTranscript: empty,
                        transcript: empty, transcriptionStatus: status, captureKind: kind), expected,
                        "status=\(status), capture=\(String(describing: kind))")
                }
            }
        }
    }

    func testPreviewKeepsReviewedThenCleanedThenRawWordsAcrossEveryState() {
        for status in ["pending", "failed", "transcribed", "complete", "", "unknown"] {
            for kind: InterjectionCaptureKind? in [.audio, .written, nil] {
                XCTAssertEqual(PlaybackMarginPreview.text(displayText: "  Reviewed words\n", cleanedTranscript: "Cleaned words", transcript: "Raw words", transcriptionStatus: status, captureKind: kind), "Reviewed words")
                XCTAssertEqual(PlaybackMarginPreview.text(displayText: " \n", cleanedTranscript: " Cleaned words ", transcript: "Raw words", transcriptionStatus: status, captureKind: kind), "Cleaned words")
                XCTAssertEqual(PlaybackMarginPreview.text(displayText: nil, cleanedTranscript: "\t", transcript: " Raw words ", transcriptionStatus: status, captureKind: kind), "Raw words")
            }
        }
    }

    func testPreviewDoesNotRewriteOrClassifyTheListenersWords() {
        for words in ["Audio saved. Transcript failed.", "Case Matters", "Cafe\u{0301} ☕", "Two\nparagraphs", String(repeating: "A", count: 4_000)] {
            XCTAssertEqual(PlaybackMarginPreview.text(displayText: words, cleanedTranscript: nil, transcript: nil,
                transcriptionStatus: "failed", captureKind: .audio), words)
        }
    }
}
