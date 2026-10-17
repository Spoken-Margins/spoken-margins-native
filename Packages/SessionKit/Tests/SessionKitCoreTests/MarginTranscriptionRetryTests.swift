import XCTest
@testable import SessionKit

/// #430: the audit found a Retry that still worked after its Margin was deleted. Each row is a state the
/// Margin or its item can be in when Retry is tapped or a failure is about to be shown.
final class MarginTranscriptionRetryTests: XCTestCase {
    private func margin(status: String = "active", audioPath: String? = "interjections/m1.m4a", kind: InterjectionCaptureKind? = nil) -> Interjection {
        Interjection(
            id: "m1", itemId: "item-a", sessionId: "session-A", targetType: .item, targetId: "item-a",
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
            audioPath: audioPath, audioStatus: "saved", transcriptionStatus: "failed",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: status, captureKind: kind
        )
    }

    func testALiveVoiceMarginWithRecordingMayRetry() {
        XCTAssertEqual(MarginTranscriptionRetry.verdict(current: margin(), itemDeletedAt: nil), .retry)
    }

    func testADeletedMarginMayNotRetry() {
        XCTAssertEqual(MarginTranscriptionRetry.verdict(current: margin(status: "deleted"), itemDeletedAt: nil), .gone)
    }

    func testAMarginMissingFromTheStoreMayNotRetry() {
        XCTAssertEqual(MarginTranscriptionRetry.verdict(current: nil, itemDeletedAt: nil), .gone)
    }

    func testAMarginWhoseItemIsInRecentlyDeletedMayNotRetry() {
        XCTAssertEqual(MarginTranscriptionRetry.verdict(current: margin(), itemDeletedAt: Date(timeIntervalSince1970: 5)), .gone)
    }

    func testADeletedMarginInADeletedItemIsGoneNotNoAudio() {
        XCTAssertEqual(
            MarginTranscriptionRetry.verdict(current: margin(status: "deleted", audioPath: nil), itemDeletedAt: Date(timeIntervalSince1970: 5)),
            .gone
        )
    }

    func testAMarginWithoutRecordingHasNothingToRetry() {
        XCTAssertEqual(MarginTranscriptionRetry.verdict(current: margin(audioPath: nil), itemDeletedAt: nil), .noAudio)
    }

    func testAWrittenMarginHasNothingToRetry() {
        XCTAssertEqual(MarginTranscriptionRetry.verdict(current: margin(kind: .written), itemDeletedAt: nil), .noAudio)
    }
}
