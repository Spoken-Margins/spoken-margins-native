import XCTest
@testable import SessionKit

/// #430: a summary or transcription failure about what's playing is a one-line tag under the title,
/// not a banner over it. Anything else, including the same failure from another listen, keeps the banner.
final class PlaybackFeedbackTagTests: XCTestCase {
    private let summaryOrigin = FeedbackOrigin(itemId: "item-a", sessionId: "session-a", work: .summary)

    private func tag(
        kind: FeedbackBannerPolicy.Kind = .error,
        origin: FeedbackOrigin?,
        offersRetry: Bool = true,
        playbackScreenVisible: Bool = true,
        playingItemId: String? = "item-a",
        playingSessionId: String? = "session-a"
    ) -> PlaybackFeedbackTag? {
        PlaybackFeedbackTag(
            kind: kind,
            origin: origin,
            offersRetry: offersRetry,
            playbackScreenVisible: playbackScreenVisible,
            playingItemId: playingItemId,
            playingSessionId: playingSessionId
        )
    }

    func testSummaryFailureOnThePlayingListenIsATagThatKeepsRetry() throws {
        let tag = try XCTUnwrap(tag(origin: summaryOrigin))
        XCTAssertEqual(tag.text, "Summary couldn’t finish")
        XCTAssertTrue(tag.isFailure)
        XCTAssertTrue(tag.offersRetry, "Retry must not be hidden by moving the status into the tag")
    }

    func testEventWithoutOriginKeepsTheBanner() {
        XCTAssertNil(tag(origin: nil))
    }

    func testLateFailureFromAnotherItemOrSessionKeepsTheBanner() {
        XCTAssertNil(tag(origin: summaryOrigin, playingItemId: "item-b"))
        XCTAssertNil(tag(origin: summaryOrigin, playingSessionId: "session-a-earlier"))
        XCTAssertNil(tag(origin: summaryOrigin, playingItemId: nil, playingSessionId: nil))
    }

    func testOffTheNowScreenTheEventKeepsTheBanner() {
        XCTAssertNil(tag(origin: summaryOrigin, playbackScreenVisible: false))
    }

    func testConfirmationsNeverBecomeATag() {
        XCTAssertNil(tag(kind: .success, origin: summaryOrigin, offersRetry: false))
    }

    func testTranscriptionFailureAndSpeechRecognitionOffReadDifferently() throws {
        let origin = FeedbackOrigin(itemId: "item-a", sessionId: "session-a", work: .marginTranscription)
        let failure = try XCTUnwrap(tag(kind: .error, origin: origin))
        XCTAssertEqual(failure.text, "Margin transcript failed")
        XCTAssertTrue(failure.isFailure)
        let off = try XCTUnwrap(tag(kind: .warning, origin: origin, offersRetry: false))
        XCTAssertEqual(off.text, "No transcript: Speech Recognition is off")
        XCTAssertFalse(off.isFailure)
        XCTAssertFalse(off.offersRetry)
    }

    func testEveryTagFitsOneLine() {
        for work in [FeedbackOrigin.Work.summary, .marginTranscription] {
            for isFailure in [true, false] {
                let text = PlaybackFeedbackTag.text(for: work, isFailure: isFailure)
                XCTAssertLessThanOrEqual(text.count, 40, text)
                XCTAssertFalse(text.contains("\n"), text)
            }
        }
    }
}
